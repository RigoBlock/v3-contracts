# Pool Token Transferability

> **Status:** implemented on `feat/implement-transfers`; parked until the product/business case for transferable pool tokens becomes clearer.

## Overview

Rigoblock SmartPool tokens implement the ERC-20 interface. Historically `transfer`, `transferFrom`, `approve` and `allowance` were no-ops or always reverted, making the tokens non-transferable. This branch introduces real ERC-20 transferability while preventing pools from holding shares of other registered pools.

## Behavior

### Transfers

- `transfer(address to, uint256 value)` and `transferFrom(address from, address to, uint256 value)` move pool tokens between holders.
- Transfers do **not** mint or burn tokens, so `totalSupply` and `effectiveSupply` are unchanged.
- The recipient's `activation` timestamp is set to the **sender's** activation time. The lockup expiration of the transferred tokens is therefore carried forward without being extended, which keeps the tokens usable in DeFi integrations (yield, looping, etc.).
- Transfers to `address(0)`, to the pool itself, and to any address registered in `PoolRegistry` are rejected with `PoolTokenCannotReceivePoolTokens(to)`.

### Approvals

- `approve(address spender, uint256 value)` sets an allowance.
- `transferFrom` enforces the allowance and decrements it on each spend.

### Pool-to-Pool Guard

Any token added to a pool's active or acceptable token lists is checked against `PoolRegistry.getPoolIdFromAddress(token)`. If the token is a registered Rigoblock pool, the addition reverts with `PoolTokenNotAllowed(token)`. This prevents:

- A pool from accepting another pool's shares as mint collateral.
- A swap/LP adapter from activating another pool's shares as an output token.

The check is performed once per token activation in `EnumerableSet.addUnique`, so it does not add per-token overhead to NAV calculations. Direct mints and transfers that target a registered pool address also revert.

## Constructor Changes

`SmartPool` now requires the canonical `PoolRegistry` address:

```solidity
constructor(
    address authority,
    address extensionsMap,
    address tokenJar,
    address poolRegistry
)
```

All deployment scripts (`deploy_extensions.ts`, `deploy_rgbk_pool.ts`, `deploy_tests_setup.ts`) and Foundry fixtures have been updated to pass `registry` as the fourth argument.

## Contract Size and the No-`viaIR` Decision

Adding ERC-20 logic and the registry checks pushed the `SmartPool` runtime bytecode above the EIP-170 limit. The current Hardhat build produces a runtime of **~25.8 KB** (1,253 bytes over the 24,576 byte mainnet limit).

**We are deliberately not using `viaIR` for `SmartPool.sol`.** The preferred path is to refactor back under the limit (extracting logic into libraries/extensions, removing non-essential code, etc.) rather than relying on the compiler's IR pipeline. The branch is parked, so the oversized contract is acceptable for continued development and testing only:

- Hardhat tests run with `allowUnlimitedContractSize: true`.
- The test fixture deploys `SmartPool` with an explicit `gasLimit` so the auto-estimated gas limit does not exceed Edr's transaction cap.

**Strategic implication:** `SmartPool` is already close to the hard EIP-170 ceiling. Even after refactoring back under the limit, there will be very little headroom for new features in the implementation contract. Any future feature that grows `SmartPool` will likely need to live in an extension/adapter/library or be paired with a corresponding size reduction.

## Risks and Open Questions

- **Secondary market / regulatory:** Transferable pool tokens may be classified as securities in some jurisdictions. The branch is intentionally parked pending legal/product review.
- **NAV denominator:** Because pool shares cannot be held by registered pools, transfers do not affect NAV denominators. A non-pool holder receiving shares does not change the set of tokens used for NAV calculation.
- **Lockup bypass:** Because transfers set the recipient's activation to the sender's, a holder could in principle move locked tokens to a fresh address to exit earlier. The branch deliberately accepts this trade-off to preserve DeFi composability; revisit if stricter lockup enforcement is required.
