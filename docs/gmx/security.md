# GMX v2 Integration — Security Analysis

## Threat Model

The GMX adapter runs via `delegatecall` in the pool's context. The pool is a multi-user vault. Security controls must:

1. Restrict order management to the pool owner
2. Prevent unbounded resource consumption (positions, fees)
3. Protect against direct (non-delegatecall) invocations
4. Guard against cross-chain misuse

---

## Access Controls

### Pool Owner Only

All order operations (`createIncreaseOrder`, `createDecreaseOrder`, `cancelOrder`, `updateOrder`, `claimFundingFees`, `claimCollateral`) are restricted to the pool owner by `MixinFallback`.

There is **no** `onlyPoolOwner` modifier inside the adapter. The protection is in the pool's `MixinFallback.fallback()`, which routes adapter calls based on caller identity:

```solidity
// MixinFallback.sol — for adapter (Authority) calls
shouldDelegatecall = msg.sender == pool().owner;

// If owner   → delegatecall  (state mutations allowed)
// If not owner → staticcall  (any state mutation reverts)
```

In the delegatecall context `msg.sender` is the original external caller (preserved through proxy → implementation → adapter dispatch). Non-owners can call adapter read-only views (routed as `staticcall`) but any write attempt reverts.

LP depositors **cannot** submit or cancel orders.

### Direct Call Protection

The `onlyDelegateCall` modifier protects against invoking the adapter at its deployed address (bypassing pool access control):

```solidity
modifier onlyDelegateCall() {
    if (address(this) == _IMPLEMENTATION) revert DirectCallNotAllowed();
    _;
}
```

`_IMPLEMENTATION` is set to `address(this)` in the constructor. A direct call will always see `address(this) == _IMPLEMENTATION` and revert.

---

## Resource Limits

### Execution Fee Cap

Each order requires a keeper execution fee paid in WETH. Without a ceiling, a malicious owner could drain the pool's WETH balance via execution fees. The adapter enforces:

```solidity
if (params.executionFee > maxExecutionFee) revert ExecutionFeeExceedsMax();
```

`maxExecutionFee` is a parameter set by governance. Excess fees above what GMX requires are refunded to the pool by the keeper after execution.

### Position Count Limit

Unbounded positions would make GMX Reader calls prohibitively expensive in the NAV loop. The adapter enforces a **32 unique-position cap** at `createIncreaseOrder` time:

```solidity
// GmxAdapterLib.assertPositionLimitNotReached (called from createIncreaseOrder only)
//
// If a matching position already exists (same market + collateralToken + isLong),
// this is an increase — no new slot is consumed, the check is skipped.
// If it is a new position, the pool must have < 32 open positions.
```

**Important implementation detail — NAV reads are unbounded:**  
The NAV loop (`_getExecutedPositionBalances`, `_getPendingOrderBalances`) always fetches ALL positions and all orders using `getAccountPositions(..., 0, type(uint256).max)`. The 32-position limit only gates _creation_, not _reading_. This means:

- A position count >32 cannot arise in steady-state (the cap prevents it).
- If it somehow arose (e.g., a race condition with many simultaneously pending orders), all positions would still be correctly counted in NAV — no positions become "invisible".
- Collateral is always accounted: `OrderVault` funds are counted via `_getPendingOrderBalances`; executed-position collateral is counted via `_getExecutedPositionBalances`. There is no window where collateral disappears from NAV.

### Callback Storage Pruning

`EGmxCallback` records two small lookup indexes so NAV can find post-close value:

- `trackedMarkets` — markets that have had pool activity, so claimable funding fees can be queried even after all positions are closed.
- `claimableCollateralKeys` — `(market, token, timeKey)` triples where a decrease/liquidation/ADL created a non-zero `CLAIMABLE_COLLATERAL_AMOUNT`.

These sets are **not hard-capped**. They grow only when value is actually owed to the pool, and they are pruned automatically:

- `claimFundingFees` removes a market from `trackedMarkets` when the pool has no open position on that market and no outstanding claimable funding fees for either token.
- `claimCollateral` removes a collateral key once its remaining claimable amount is zero.

In steady state the 32 open-position limit keeps the scan small; in the worst case the scan grows linearly with the number of historic markets that still hold unclaimed value.

### Callback Gas Limit

Pool-initiated decrease orders set `callbackContract: address(this)` with a callback gas limit of `500_000`. This caps the gas GMX keepers forward back to the pool callback when the pool owner voluntarily closes a position.

This limit does **not** apply to keeper-triggered liquidation or ADL callbacks. Those are initiated by GMX's `LiquidationUtils` / `AdlUtils`, which use the protocol's own `MAX_CALLBACK_GAS_LIMIT = 4_000_000`. The `500_000` value is therefore only a cost-control knob for owner-triggered closes and does not constrain the main claimable-collateral path (liquidation/ADL).

### Pending-Order NAV Accounting

`_getPendingOrderBalances` values assets currently held in GMX's `OrderVault`:

| Order type                                              | Counted in NAV                                  | Notes                                                                                                                            |
| ------------------------------------------------------- | ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `MarketIncrease` / `LimitIncrease`                      | `initialCollateralDeltaAmount` + `executionFee` | Both collateral and fee move to the vault on creation.                                                                           |
| `MarketDecrease` / `LimitDecrease` / `StopLossDecrease` | `executionFee` only                             | Position collateral stays in the DataStore and is valued by `_getExecutedPositionBalances`; counting it here would double-count. |
| Swap orders                                             | `executionFee` only                             | `AGmxV2` does not create swap orders. If they were created, the input amount would also need to be counted.                      |

Because decrease-order execution fees are now counted, a pending decrease no longer creates a temporary NAV gap for the fee portion.

**Pending-order race condition (acknowledged, not fixed):**  
`createIncreaseOrder` checks the count of _executed_ positions at call time. Multiple `createIncreaseOrder` calls before any keeper execution can in theory queue more than 32 orders. However:

1. Each call transfers real collateral from the pool (the pool owner is spending pool funds).
2. Once executed, all resulting positions are unconditionally included in NAV via the unbounded read.
3. Pending-order collateral and all execution fees are already counted, so NAV does not drop when orders are created and does not rebound artificially when they execute.
4. The gas cost per NAV calculation is bounded in practice because the pool owner has finite collateral and each position needs a separate market/direction/collateral combination with a real execution fee.

---

## Chain Guard

GMX v2 perpetuals are deployed on Arbitrum One only (`chainId = 42161`). An on-chain guard prevents deployment on incorrect chains:

```solidity
if (block.chainid != _ARB_CHAIN_ID) revert NotArbitrum();
```

This is checked at every adapter entry point. Pools on Ethereum mainnet, Base, Optimism, etc., cannot call GMX functions even if the adapter bytecode is present in the Authority registry.

---

## Reentrancy Protection

The pool's `ReentrancyGuardTransient` (EIP-1153 transient storage) prevents reentrant calls during any state-changing delegatecall. This wraps the full dispatch path, not just individual adapters.

---

## GMX Protocol Constraints (Documented Behaviours)

These are GMX-native behaviours — not bugs in the adapter — that callers should be aware of:

### 1. Order Cancellation Delay (REQUEST_EXPIRATION_TIME)

User-initiated order cancellations require a minimum 300-second (5-minute) wait after order creation. Attempting to cancel earlier reverts with:

```
RequestNotYetCancellable
```

This is enforced by GMX's `DataStore` key:

```
keccak256(abi.encode("REQUEST_EXPIRATION_TIME")) → 300
```

The adapter does not add extra delay; it passes the call through directly. Frontends should surface this constraint.

### 2. claimCollateral Reverts on Zero Claimable

The deployed GMX `ExchangeRouter` (at `0x1C3fa76e6E1088bCE750f23a5BFcffa1efEF6A41`) has an arithmetic underflow panic when `claimableAmount = 0`. Callers must verify collateral is available before calling `claimCollateral`. The adapter does not add a pre-flight check because:

- On-chain read cost would be wasted if claimable > 0 (the common path)
- The revert from ExchangeRouter is sufficient to surface the condition

### 3. MarketIncrease Orders Are Not Updatable

`updateOrder` only works for limit-type orders (`LimitIncrease`, `LimitDecrease`, `StopLossDecrease`). Calling it on `MarketIncrease` or `MarketDecrease` reverts with:

```
OrderNotUpdatable(uint256 orderType)
```

The adapter passes through to GMX without type-filtering. Frontends should disable the update action for market orders.

---

## Collateral Token Handling

For WETH (wrapped native) collateral orders, the adapter sends `initialCollateralDeltaAmount + executionFee` to the OrderVault in a single WETH transfer. This is required because GMX deducts the execution fee from the vault's WNT balance — sending only `collateralAmount` would result in less collateral than intended entering the position.

For non-WETH collateral tokens, two separate transfers are made:

1. Collateral token → `initialCollateralDeltaAmount`
2. WETH → `executionFee`

The adapter uses `SafeTransferLib` for all transfers, ensuring USDT-compatible behaviour (force-reset before approve if needed).

---

## NAV Manipulation Considerations

**Can a pool owner inflate NAV via GMX positions?**

Open positions are valued using Chainlink prices via `GmxChainlinkPriceFeedProvider`. Chainlink feeds on Arbitrum have heartbeat intervals (0.5-1%) that bound manipulation. PnL is computed by GMX's Reader using the same oracle. The effective manipulation bound is the same as Chainlink manipulation tolerance — no amplification introduced by the adapter.

**Can a pool owner drain liquidity via execution fees?**

Bounded by `maxExecutionFee`. Excess fees above what GMX uses are refunded by the keeper. Net drain per order is bounded.

---

## Arbitrum Sequencer Uptime

**Why it matters for NAV:**

`GmxLib._safeGetGmxPrice` calls `ChainlinkPriceFeedProvider.getOraclePrice()` directly — bypassing GMX's `Oracle.validateSequencerUp()`. If the Arbitrum sequencer is down or has recently restarted, the Chainlink feeds return stale L2 prices without reverting.

**Design decision — accept stale prices:**

Returning stale Chainlink prices is intentionally accepted rather than triggering a fallback to `_collateralOnlyBalances`. The reason: stale prices are far more accurate than zero PnL.

- A position with large unrealized PnL (positive or negative) or accumulated funding fees would produce dramatic NAV distortion if PnL were set to zero.
- Sequencer outages on Arbitrum are rare (minutes to hours) and occur at the L2 sequencer level, not at the L1 Chainlink oracle level — the last price pushed to L1 before the outage is recent and reasonable.
- This is the same approach taken by audited external integrations.
- The only alternative — reverting `EApps.getAppTokenBalances` — would DoS all pool operations (deposit, withdraw, NAV update) for the entire outage duration, which is a worse outcome.

**Consequence:** During a sequencer outage, GMX PnL in NAV is computed from the last known Chainlink prices. These will be slightly stale but not fabricated. This is acceptable and consistent with how GMX itself handles price continuity across its oracle layers.

---

## NAV Coverage and Dependency Fallbacks

The `EGmxCallback` extension automatically tracks price-impact rebate collateral and accrued funding fees on fully-closed markets, so both value classes are reflected in NAV as soon as the relevant GMX execution events occur. The pool owner still calls `claimCollateral` / `claimFundingFees` to recover the assets, but NAV accounting no longer depends on those manual claims.

**Reader/oracle failures** are handled with graceful fallbacks (`try/catch` on Reader calls; zero-price guard in `_computeGmxNetCollateral`; collateral-only fallback if `getAccountPositionInfoList` reverts). Reverting every NAV-sensitive operation during a dependency outage would be a worse outcome, so the design accepts temporarily less accurate pricing rather than a full protocol halt.

---

## No Referral Code

The adapter does not accept or store a referral code. All orders pass `referralCode: bytes32(0)` to GMX.

**Why removed:** A referral code is registered by a specific address that earns GMX token rebates when the code is used. If the pool operator registered their own code and used it for pool trades:

- The pool gets a fee discount (reduces trading cost → benefits LPs ✓)
- The operator's EOA gets a GMX token rebate from every trade (value extracted from the system at the expense of GMX's treasury, not the pool's assets directly, but represents a conflict of interest)

Hardcoding `bytes32(0)` removes this conflict entirely with no impact on trading functionality. No discount is earned, but no referrer is enriched.

---

## Audit Agent Findings

The following findings were raised by an audit-agent review of `EGmxCallback.sol` and `GmxCallbackLib.sol` on a previous commit.

### 1. Missed GMX callbacks permanently hide historical claimable-collateral buckets from NAV accounting

- **Severity:** Low
- **Contracts:** `contracts/protocol/extensions/EGmxCallback.sol`
- **Description:** `afterOrderExecution` is the only on-chain path that records `(market, token, timeKey)` collateral keys. GMX invokes callbacks inside a `try/catch`, so order execution continues even if the callback reverts (for example, because the callback gas limit is too low or the payload cannot be decoded). When that happens the pool still owns a real claimable-collateral bucket in GMX's DataStore, but the extension never records the key, so the rebate is excluded from on-chain NAV until it is claimed.
- **Status:** Acknowledged / not fixed.
- **Rationale:** The `timeKey` and `market` are publicly observable from the executed order event and block timestamp, so operators can reconstruct missed buckets off-chain and call `claimCollateral` on behalf of the pool. Liquidation/ADL callbacks use GMX's `MAX_CALLBACK_GAS_LIMIT` (4M), making failure unlikely; owner-initiated decrease callbacks use 500k, which is a monitored, owner-controlled parameter.

### 2. Unbounded GMX callback tracking sets can grow until NAV-dependent operations run out of gas

- **Severity:** Low
- **Contracts:** `contracts/protocol/extensions/EGmxCallback.sol`, `contracts/protocol/libraries/GmxCallbackLib.sol`
- **Description:** `trackedMarkets` and `claimableCollateralKeys` grow with every new market or `timeKey` bucket that produces value. The 32 open-position limit bounds concurrent positions, but it does not bound historical markets or time buckets. Downstream NAV logic iterates these sets in a single call, so gas cost scales with lifetime size rather than current position count.
- **Status:** Acknowledged / not fixed.
- **Rationale:** The sets are pruned automatically when value is claimed — `claimFundingFees` removes markets with no open position and no outstanding funding, and `claimCollateral` removes fully-claimed keys. The pool operator is the only party who can create entries, and the 32 open-position limit bounds active activity. A hard cap on the sets was considered and rejected because it can prevent new legitimate markets from being tracked while old, unclaimed value still occupies slots.

## Audit Agent Findings (GmxLib)

The following findings were raised by an audit-agent review of `GmxLib.sol`.

### 3. 32-position limit can be bypassed with pending increase orders

- **Severity:** Low
- **Contract:** `contracts/protocol/libraries/GmxLib.sol`
- **Description:** `assertPositionLimitNotReached` counts only executed positions via `getAccountPositions`. A pool owner could issue many `MarketIncrease` / `LimitIncrease` orders before keepers execute them; once executed, the pool could hold more than 32 positions.
- **Status:** Acknowledged / not fixed.
- **Rationale:** The 32-position cap is a gas heuristic, not a security invariant. Only the pool owner can create orders, and each order transfers real collateral from the pool. NAV accounting already reads positions and orders unboundedly (`type(uint256).max`), so no value becomes invisible if the cap is exceeded. The operational risk is bounded by owner-controlled collateral and execution fees.

### 4. Claimable-collateral delay subtraction can underflow

- **Severity:** Low
- **Contract:** `contracts/protocol/libraries/GmxLib.sol`
- **Description:** `_getClaimableCollateralAmount` computes `block.timestamp - info.timeKey * CLAIMABLE_COLLATERAL_TIME_DIVISOR`. If GMX governance increases the divisor after a `timeKey` is recorded, the product can exceed `block.timestamp` and cause a panic underflow, reverting NAV queries.
- **Status:** Fixed.
- **Fix:** The subtraction is now saturated at zero (`block.timestamp > maturityTime ? ... : 0`), so an increased divisor is treated as "not yet vested" instead of reverting. The full claimable-collateral math still mirrors GMX's own `claimCollateral` logic for the vested case.

### 5. Collateral-only fallback can overstate NAV during oracle/reader failures

- **Severity:** Info
- **Contract:** `contracts/protocol/libraries/GmxLib.sol`
- **Description:** If `getAccountPositionInfoList` reverts or the collateral token price is zero, `_computeGmxNetCollateral` and `_fetchPositionInfos` fall back to the raw `collateralAmount`, ignoring negative PnL, price impact, and fees.
- **Status:** Acknowledged / by design.
- **Rationale:** This fallback is intentionally conservative: it reports the highest plausible on-chain collateral rather than zero or a reverted NAV. Reverting all NAV-dependent operations (deposits, withdrawals, NAV updates) during a transient oracle or Reader outage would be a worse outcome than a temporary, bounded overstatement. The fallback is documented in `docs/gmx/nav-accounting.md`.

## Audit Notes

- All entry points: chain guard (`ARBITRUM_CHAIN_ID`) → delegatecall guard (`onlyDelegateCall`) → owner routing in `MixinFallback` (`shouldDelegatecall = msg.sender == pool().owner`)
- No storage declared in adapter (pure delegatecall model)
- Immutables eliminate any storage-collision risk for GMX addresses
- `SafeTransferLib` used for all token operations
- No inline assembly except in upstream library (`VirtualStorageLib`, `StorageLib`)
