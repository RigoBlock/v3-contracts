# Uniswap Integration — Known Issues and Accepted Design Decisions

This document records known limitations and accepted risks of the Uniswap adapter
(`AUniswapRouter` / `AUniswapDecoder`) so that recurring security reviews do not
re-litigate settled questions. Each entry states the behavior, why it is accepted,
and what would change the disposition.

For the transaction flow and decoding model see
[UNISWAP_TRANSACTION_FLOW.md](./UNISWAP_TRANSACTION_FLOW.md).

## Fail-closed command surface (UR 2.1.2)

### `ACROSS_V4_DEPOSIT_V3` (0x40) is intentionally unsupported

UR 2.1.2 reserved `0x40` for Across V4 deposits. The adapter reverts
`InvalidCommandType(0x40)` (also with the allow-revert flag, `0xc0`).

**Why:** Across can move tokens, and Permit2 holds a persistent allowance to the
Universal Router. Forwarding an undecoded `0x40` would be a fund-exfiltration path.
Fail-closed is the security-correct behavior.

**If product wants Across deposits:** this must become an explicit allow-list
(spoke pool, recipient, token) in the decoder — never a silent decode.

Covered by `test_Execute_AcrossV4DepositV3Command_Reverts` and
`test_Execute_AcrossV4DepositV3Command_AllowRevertFlag_Reverts`.

### `COMMAND_TYPE_MASK` (0x7f) is load-bearing

The adapter must keep compiling against the UR 2.1.2 `Commands.sol`. The 2.1.2 mask
(`0x7f`) is what makes reserved commands such as `0x40` revert instead of being
collapsed onto `0x00` (`V3_SWAP_EXACT_IN`) as the old `0x3f` mask would. Do not
vendor a pre-2.1.2 `Commands.sol` while the decoder targets a 2.1.2 router.

### V4_SWAP actions below SETTLE that are not swap types revert

Any V4 action `< SETTLE (0x0b)` other than the four swap types reverts
`UnsupportedAction` at decode time (previously skipped, i.e. fail-open; hardened in
PR #965). This includes the deprecated `*_FROM_DELTAS` actions.

Covered by `test_Execute_V4Swap_UnknownActionBelowSettle_Reverts`.

## Residual risks (accepted, pre-existing)

### Balances left on the Universal Router

A plan whose final recipient is the router itself (e.g. a swap with
`recipient = ADDRESS_THIS`) without a trailing `SWEEP` leaves tokens on the UR.
Anyone can then take them via a UR command where the pool pays (the pool approved
Permit2 → UR). This is a dust/footgun risk, not a drain of un-backed value: the
tokens left on the UR are counted in pool NAV while they sit on the router.
Mitigation: always end plans with `SWEEP(token, pool, 1)`. See
`test_Execute_PayPortionFullPrecision_ToPool_Succeeds` for the canonical pattern.

### Decoder records path endpoints, not intermediates

For V2/V3 swaps only the first and last path tokens are registered
(`tokensIn`/`tokensOut`); intermediate hop tokens are not. This is sufficient for
approval and price-feed gating of the tokens that actually enter/leave the pool.
The decoder must not be treated as a full token-flow taint map.

### `payerIsUser` is not inspected

The decoder does not branch on the V3 `payerIsUser` flag. Input-side safety comes
from the fact that the adapter only ever ERC20-approves the decoded `tokensIn`
(to Permit2, block-scoped), so the UR can pull at most the decoded input tokens
from the pool.

### `params.value` can under-count native input

Flag-amount semantics (`CONTRACT_BALANCE`, `SETTLE_ALL`) are resolved at execution
time inside the UR; the decoder's `params.value` is an estimate used to forward
native value. Failure mode is revert or stuck dust, not a new spend path.

### Persistent Permit2 allowance

The adapter keeps a max ERC20 allowance pool → Permit2 (checked with a threshold),
with per-call `Permit2.approve(router, type(uint160).max, 0)` so the UR's pull is
valid only within the current block. This is the standard Permit2 integration
pattern; revocation is not planned.

### Third-party fee recipients are a policy, not a bug

`PAY_PORTION` / `PAY_PORTION_FULL_PRECISION` to any recipient other than the pool
(or the router/MSG_SENDER mappings) revert `RecipientNotSmartPoolOrRouter` at decode
time. Uniswap-API calldata with fee legs to third parties keeps reverting — this is
intentional vault policy. Supporting such fees would require a fee-recipient
allow-list, not a relaxation of `_processRecipients`.

## Deploy-time invariants

### Adapter artifact must be the isolated 0.8.37 build

`AUniswapRouter` is pinned to `pragma solidity 0.8.37` and compiled in its own
forge/hardhat job; fork tests deploy it via `deployCode` on the precompiled
artifact. When deploying:

- verify the deployed bytecode was built with solc 0.8.37 (metadata) and the
  production optimizer settings from CI (`SOLIDITY_SETTINGS`),
- verify the constructor `universalRouter` argument against the official UR 2.1.2
  address table (see `src/utils/constants.ts`),
- the local `.env` must not pin `SOLIDITY_VERSION` to an older compiler, or the
  deployment artifact will differ from the reviewed one.

### `minHopPriceX36` is not part of the security gate

UR 2.1.2 added an optional `uint256[] minHopPriceX36` per-hop floor to V2/V3 swap
inputs (ABI index 5). The decoder reads the path at index 3, unchanged. The adapter
does not interpret hop floors; an empty array equals 2.0 behavior. A missing
`minHopPriceX36` in decoded data is not a bug.
