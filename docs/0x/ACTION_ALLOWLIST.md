# 0x Settler Action Validation

Security model and validation logic of `A0xRouter`. Historically the adapter filtered every action
selector against an allowlist; **the allowlist was removed** (see "Why no action filtering" below).
This document describes what the adapter still enforces and why.

## What the adapter validates

1. **Genuine settler.** The target must be the current or previous Feature 2 (Taker Submitted)
   settler resolved from the 0x Deployer registry (`_requireGenuineSettler`). This prevents a
   counterfeit contract from receiving the pool's tokens and native value.
2. **Top-level recipient.** `AllowedSlippage.recipient == address(this)` — the swap's final output
   always lands in the pool.
3. **Buy-token price feed.** `buyToken` must have a price feed in the oracle (the 0x ETH sentinel is
   mapped to `address(0)`), and is added to the pool's active tokens so NAV accounting picks it up.
4. **TRANSFER_FROM recipient.** Each `TRANSFER_FROM` action must route the pool's sell tokens to the
   settler itself. This blocks the simplest phishing drain, where crafted calldata pulls tokens from
   the pool to an arbitrary address before any DEX action runs.

Everything else in the settler calldata — action selectors, targets, calldata, `minAmountOut` — is
passed through untouched.

## Why no action filtering

An earlier version of the adapter whitelisted action selectors (DEX actions such as `UNISWAPV3`,
plus `BASIC`) and blocked `RFQ`, `RENEGADE`, `METATXN_*`, and unknown selectors. The rationale for
blocking `RFQ` was that off-chain pricing has no on-chain reference, so a rogue maker combined with
a phished submitter could settle at any price. That rationale turned out to be incoherent:

- `BASIC` — which the allowlist **allowed** — takes an arbitrary `target` and arbitrary calldata and
  is used by the 0x API for native wrapping/unwrapping and affiliate-fee transfers
  (`lib/0x-settler/src/core/Basic.sol`). An operator-controlled `BASIC` can transfer pool tokens to
  any address, so the RFQ exclusion blocked nothing the operator couldn't already do with an
  allowed action.
- `minAmountOut` was never validated either; a compromised submitter can sandwich any swap
  regardless of which actions it contains.

Since the operator trust model already governs the adapter (see below), selector filtering added no
security — it only made the adapter fragile: 0x upgrades deployed settlers independently of the
pinned `0x-settler` submodule (e.g. live settlers dispatch a 4-param `POSITIVE_SLIPPAGE` that the
pinned submodule does not contain), so every 0x-side selector change broke previously valid quotes
with `ActionNotAllowed` until the adapter was redeployed.

Filtering was removed entirely. The integration is now robust to 0x-side action changes by
construction, and breaking changes in the settler ABI surface are caught by tests instead:

- `test/extensions/A0xActions.t.sol` — calldata-format canaries pinning the `execute` selector and
  the production `POSITIVE_SLIPPAGE` selector against the pinned submodule, so a submodule bump that
  changes them fails loudly and prompts a review of the parsing assumptions.
- `test/extensions/A0xRouterFork.t.sol` / `A0xRouterUnichainFork.t.sol` — replay of real 0x
  transactions against live settlers on Unichain, Optimism, and Arbitrum. These are the
  authoritative guard that current 0x payloads execute; they must be re-extracted and extended
  whenever 0x materially changes its settler format.

Note that the adapter still accepts the superset of what any chain's settler dispatches: an action
not implemented on the current chain reverts inside the settler with `ActionInvalid`, which is
expected and is not an adapter bug.

## What `BASIC` is used for

The 0x API includes `BASIC` actions in ordinary quotes:

1. **Wrap native → wrapped native** — native value is sent to the wrapped-native contract, which
   credits the settler; the final slippage check forwards it to the pool.
2. **Unwrap wrapped native → native** — `wrappedNative.withdraw(amount)`, with the native output
   forwarded to the pool.
3. **Affiliate/protocol fees** — a `bps`-sized transfer to a fee recipient. The adapter does not
   second-guess these fees, exactly as it does not second-guess `minAmountOut`; a pool operator who
   wants zero fees should request a zero-fee quote.

The settler's own `_isRestrictedTarget()` prevents `BASIC` from calling Permit2, AllowanceHolder,
or the settler itself, so it cannot be used as a confused deputy against those contracts.

## Trust model: operator is not trustless

`A0xRouter` is called via `delegatecall` from a pool only when the caller is the pool owner or a
delegated address (`MixinFallback.sol`). The adapter is an execution vehicle, not a custody guard.
A malicious or compromised operator can already extract value through any swap adapter by:

- setting an extremely unfavorable `minAmountOut` and sandwiching the trade from an external wallet,
- routing the pool into a worthless or attacker-controlled token that satisfies the price-feed check,
- crafting any calldata the settler will execute (including `BASIC` transfers to arbitrary
  recipients).

Therefore no selector-level filter can protect pool holders from their own operator; the pool
holder's protection is choosing the operator, plus the operator's economic incentive to keep NAV
high. Reported "bugs" that require a rogue or phished operator to craft settler calldata are
out of scope for the bug bounty program — they reduce to the documented operator trust model.

## Open security enhancements

- **0x fees** ([issue #864](https://github.com/RigoBlock/v3-contracts/issues/864))  
  Both 0x protocol fees and optional affiliate fees are paid through the `BASIC` action. Because the
  fee recipient is encoded in the calldata, the adapter could overwrite the fee recipient with the
  pool address (or zero the bps) so the fee amount remains in the pool rather than leaking to an
  arbitrary address. The swap still executes correctly when the fee recipient is overwritten or the
  bps are zeroed; the fee is a calldata-encoded transfer, not a settlement invariant.

## Upgrade considerations

- **Settler instance upgrades** (new deployments via the Deployer registry): handled automatically
  by `_requireGenuineSettler`, which checks `ownerOf` (current) and `prev` (dwell-time fallback).
- **New action selectors** (new DEX integrations added to `ISettlerActions`): pass through without
  an adapter change — they only need to be implemented by the chain's settler.
- **Settler ABI changes** (selector or `execute` layout changes): caught by the canary tests; the
  parsing offsets below must be reviewed and the fork replay fixtures re-extracted.
- **Bridge settlers** (Feature 5): implicitly rejected because they have different addresses in the
  Deployer registry. Cross-chain actions embedded in a Feature 2 settler would fail at the settler's
  own `_checkSlippageAndTransfer` because bridged tokens don't arrive on the same chain in the same
  transaction.

## Calldata parsing

Settler provides `CalldataDecoder.decodeCall()` in `SettlerBase.sol`, but it operates on
`bytes[] calldata` with raw assembly pointer math. A0xRouter receives a single `bytes calldata data`
blob (the full ABI-encoded settler call), so it parses the standard ABI encoding directly to locate
the action array and the `TRANSFER_FROM` recipient. There is no reusable library shortcut for this.

ABI layout of `Settler.execute(AllowedSlippage, bytes[], bytes32)`:

- `data[0:4]` — function selector
- `data[4:36]` — `AllowedSlippage.recipient` (address)
- `data[36:68]` — `AllowedSlippage.buyToken` (IERC20 = address)
- `data[68:100]` — `AllowedSlippage.minAmountOut` (uint256)
- `data[100:132]` — offset to `bytes[] actions` (relative to `data[4:]`)
- `data[132:164]` — `bytes32` (permit2 signature placeholder)

## Approval pattern

A0xRouter approves `type(uint256).max` to AllowanceHolder before each call, then resets to `1`
after success. This gives maximum gas savings on both sides:

- **Before**: ERC20 spec says `transferFrom` skips the allowance SSTORE when allowance is
  `type(uint256).max`, saving ~5000 gas inside AllowanceHolder's transfer.
- **After**: Resetting to `1` (not `0`) keeps the storage slot warm. Next call's `safeApprove`
  pays 5000 gas (non-zero → non-zero) instead of 20000 (zero → non-zero).
- **Security**: No hanging approvals — the approval is always `1` between calls.
- **Revert safety**: If the call reverts, the approval is unwound automatically (EVM reverts
  all state changes including the `safeApprove`).

This differs from the Permit2 pattern (used in AUniswapRouter) where a persistent max ERC20
approval to Permit2 is safe because Permit2 requires a second per-call `permit2.approve()` to
the spender. AllowanceHolder has no such second layer, so we set and reset.
