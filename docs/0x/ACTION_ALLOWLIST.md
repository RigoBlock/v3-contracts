# 0x Settler Action Allowlist

Security rationale for the action allowlist in `A0xRouter`.

## Architecture

The 0x API routes swaps through Settler contracts. Each swap contains a `bytes[] actions` array
where each element starts with a 4-byte action selector (e.g., `UNISWAPV3`, `BASIC`).
A0xRouter validates every action selector against a whitelist before forwarding to AllowanceHolder.

## Blocked Actions

### BASIC
Calls arbitrary `pool` address with arbitrary `data`. An attacker could craft calldata that invokes
`token.transfer()` or `token.approve()` through BASIC, draining pool assets.

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

## Allowed Actions

All allowed actions route through hardcoded DEX protocol contracts with deterministic behavior:

| Action | Protocol |
|--------|----------|
| TRANSFER_FROM | ERC20 pull |
| NATIVE_CHECK | ETH balance assertion |
| POSITIVE_SLIPPAGE | Surplus capture |
| UNISWAPV2 | Uniswap V2 |
| UNISWAPV3 / UNISWAPV3_VIP | Uniswap V3 |
| UNISWAPV4 / UNISWAPV4_VIP | Uniswap V4 |
| BALANCERV3 / BALANCERV3_VIP | Balancer V3 |
| PANCAKE_INFINITY / PANCAKE_INFINITY_VIP | PancakeSwap |
| CURVE_TRICRYPTO_VIP | Curve |
| MAVERICKV2 / MAVERICKV2_VIP | Maverick V2 |
| DODOV1 / DODOV2 | DODO |
| VELODROME | Velodrome |
| MAKERPSM | Maker PSM |
| BEBOP | Bebop |
| EKUBO / EKUBOV3 / EKUBO_VIP / EKUBOV3_VIP | Ekubo |
| EULERSWAP | Euler |
| LFJTM | Lifinity/JTM |
| HANJI | Hanji |

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
