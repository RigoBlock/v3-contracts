# 0x Settler Action Allowlist

Security rationale for the action allowlist in `A0xRouter`.

## Architecture

The 0x API routes swaps through Settler contracts. Each swap contains a `bytes[] actions` array
where each element starts with a 4-byte action selector (e.g., `UNISWAPV3`, `BASIC`).
A0xRouter validates every action selector against a whitelist before forwarding to AllowanceHolder.

## Allowed Actions

Most allowed actions route through hardcoded DEX protocol contracts with deterministic behavior.

| Action | Protocol / Purpose |
|--------|-------------------|
| TRANSFER_FROM | ERC20 pull |
| NATIVE_CHECK | ETH balance assertion |
| POSITIVE_SLIPPAGE | Surplus capture |
| UNISWAPV2 | Uniswap V2 |
| UNISWAPV3 / UNISWAPV3_VIP | Uniswap V3 |
| UNISWAPV4 / UNISWAPV4_VIP | Uniswap V4 |
| BALANCERV3 / BALANCERV3_VIP | Balancer V3 |
| PANCAKE_INFINITY / PANCAKE_INFINITY_VIP | PancakeSwap |
| CURVE_TRICRYPTO_VIP | Curve (Arbitrum only in current 0x Settler deployments) |
| MAVERICKV2 | Maverick V2 |
| DODOV1 / DODOV2 | DODO |
| MAKERPSM | Maker PSM |
| BEBOP | Bebop |
| EKUBO / EKUBOV3 / EKUBOV3_VIP | Ekubo |
| EULERSWAP | Euler |
| HANJI | Hanji |
| CHECK_SLIPPAGE | Exact-output slippage check & payout to vault |
| BASIC | Native wrapping/unwrapping and optional 0x affiliate fees (see below) |

> ⚠️ **Allowlist vs. chain-specific 0x support**  
> The list above is the adapter-level allowlist: selectors not on it are rejected with
> `ActionNotAllowed`. 0x Settler dispatch is chain-specific; an allowed selector that is not
> implemented on the current chain will revert inside the Settler with `ActionInvalid`. For example,
> `VELODROME` is not currently dispatched by any TakerSubmitted Settler in the pinned 0x-settler
> submodule, and `EULERSWAP` is commented out on Base. Do not treat these as adapter bugs; the
> adapter intentionally accepts the superset so it does not need per-chain redeployments every time
> 0x adds or removes a DEX on a single chain.

### `BASIC` — why it is allowed

`BASIC` is **not** a generic DEX action in our integration; it is required by the 0x API for
chain-native wrapping/unwrapping and for optional affiliate-fee payments. The current usage is:

1. **Wrap native → wrapped native**  
   `BASIC(sellToken = 0xEeee...ee, bps, target = wrappedNative, offset = 0, data = "")`  
   Sends native currency to the wrapped-native contract, which credits wrapped native back to the
   Settler. The final slippage check then forwards the wrapped native to the pool.

2. **Unwrap wrapped native → native**  
   `BASIC(sellToken = wrappedNative, bps, target = wrappedNative, offset = 4, data = withdraw(0))`  
   Calls `wrappedNative.withdraw(amount)`. The Settler receives native currency, which the final
   slippage check forwards to the pool.

3. **Optional 0x affiliate fee** (currently accepted, see security note below)  
   `BASIC(sellToken = feeToken, bps = swapFeeBps, target = swapFeeRecipient, offset = 0, data = "")`  
   Transfers a portion of the trade to an arbitrary fee recipient. This is the same trust model as
   any pool-operator-controlled swap: the operator (or a delegated agent) chooses the quote, and a
   fee is just a cost of execution.

The Settler's own `_isRestrictedTarget()` prevents `BASIC` from calling Permit2, AllowanceHolder,
or the Settler itself, so it cannot be used as a confused-deputy attack against those contracts.

## Blocked Actions

### RFQ / RFQ_VIP
Off-chain pricing with no on-chain reference. A rogue market maker combined with a phished
transaction submitter can set any price. The `recipient` and `buyToken` checks in
`_validateSettlerCalldata` don't help because `minAmountOut` is controlled by the same
(potentially compromised) submitter.

### RENEGADE
Dark pool DEX protocol. Its settler action takes `(address target, address baseToken, bytes data)` —
arbitrary target with arbitrary calldata. Functionally identical risk to BASIC.

### METATXN_* variants
Designed for the `executeMetaTxn` flow, not the `execute` (Taker Submitted) flow used by this
adapter. Unnecessary attack surface — blocked by default.

### Unknown selectors
Any selector not in the allowlist is blocked. This provides forward security: when 0x adds new
action types to `ISettlerActions`, they are blocked until the adapter is explicitly updated.

## Trust model: operator is not trustless

`A0xRouter` is called via `delegatecall` from a pool only when the caller is the pool owner or a
delegated address (`MixinFallback.sol`). The adapter is an execution vehicle, not a custody guard.
A malicious or compromised operator can already extract value through any swap adapter by:

- setting an extremely unfavorable `minAmountOut` and sandwiching the trade from an external wallet,
- routing the pool into a worthless or attacker-controlled token that satisfies the price-feed check.

Therefore, `BASIC` does not introduce a new class of fund loss. It is constrained to the same
operator-trust assumption as `UNISWAPV3`, `UNISWAPV4`, etc. For the same reason the adapter does not
second-guess `minAmountOut`: the operator is expected to quote and execute swaps in the pool's
interest, exactly as with the Uniswap adapter.

## Open security enhancements

- **0x fees** ([issue #864](https://github.com/RigoBlock/v3-contracts/issues/864))  
  Both 0x protocol fees and optional affiliate fees are paid through the `BASIC` action. Because the
  fee recipient is encoded in the calldata, the adapter can overwrite the fee recipient with the pool
  address (or set the fee bps to zero) so the fee amount remains in the pool rather than leaking to an
  arbitrary address. This is the same approach already used for other aggregator integrations. The
  swap still executes correctly when the protocol-fee recipient is overwritten or the bps are zeroed;
  the protocol fee is just a calldata-encoded transfer, not a settlement invariant.

- **Wrapped-native-only `BASIC`**  
  A future adapter could pass the chain-specific `wrappedNative` address to the constructor and
  enforce `target == wrappedNative` for every `BASIC` action (e.g., by overwriting the target in the
  calldata). This would remove fee support and block any future non-WETH use of `BASIC`. Because the
  operator can still extract value in other ways, this is a defense-in-depth improvement, not a critical
  fix.

## Upgrade Considerations

- **Settler instance upgrades** (new deployments via Deployer registry): handled automatically by
  `_requireGenuineSettler`, which checks `ownerOf` (current) and `prev` (dwell-time fallback).
- **New action selectors** (new DEX integrations added to `ISettlerActions`): blocked by default.
  Require adapter redeployment to add them to the allowlist.
- **Bridge settlers** (Feature 5): implicitly rejected because they have different addresses in the
  Deployer registry. Cross-chain actions embedded in a Feature 2 settler would fail at the settler's
  own `_checkSlippageAndTransfer` because bridged tokens don't arrive on the same chain in the same
  transaction.

## Calldata Parsing

Settler provides `CalldataDecoder.decodeCall()` in `SettlerBase.sol`, but it operates on
`bytes[] calldata` with raw assembly pointer math. A0xRouter receives a single `bytes calldata data`
blob (the full ABI-encoded settler call), so it parses the standard ABI encoding directly to locate
action selectors. There is no reusable library shortcut for this.

ABI layout of `Settler.execute(AllowedSlippage, bytes[], bytes32)`:
- `data[0:4]` — function selector
- `data[4:36]` — `AllowedSlippage.recipient` (address)
- `data[36:68]` — `AllowedSlippage.buyToken` (IERC20 = address)
- `data[68:100]` — `AllowedSlippage.minAmountOut` (uint256)
- `data[100:132]` — offset to `bytes[] actions` (relative to `data[4:]`)
- `data[132:164]` — `bytes32` (permit2 signature placeholder)

## Approval Pattern

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
