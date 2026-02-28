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

All order operations (`createIncreaseOrder`, `createDecreaseOrder`, `cancelOrder`, `updateOrder`, `claimFundingFees`, `claimCollateral`) are gated by:

```solidity
modifier onlyPoolOwner() {
    if (msg.sender != StorageLib.pool().owner) revert CallerIsNotOwner();
    _;
}
```

In the delegatecall context, `msg.sender` is the original external caller (preserved through proxy → implementation → adapter dispatch). This means only the pool owner can invoke GMX operations.

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

Unbounded positions would make GMX Reader calls prohibitively expensive (gas, latency) for NAV calculations. The adapter limits to 32 concurrent positions:

```solidity
function _assertPositionLimitNotReached() private view {
    require(
        _reader.getAccountPositions(_dataStore, address(this), 0, _MAX_GMX_POSITIONS).length
            < _MAX_GMX_POSITIONS,
        MaxGmxPositionsReached()
    );
}
```

This is checked at `createIncreaseOrder` time only. Existing positions are not retroactively constrained.

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

## No Referral Code

The adapter does not accept or store a referral code. All orders pass `referralCode: bytes32(0)` to GMX.

**Why removed:** A referral code is registered by a specific address that earns GMX token rebates when the code is used. If the pool operator registered their own code and used it for pool trades:
- The pool gets a fee discount (reduces trading cost → benefits LPs ✓)
- The operator's EOA gets a GMX token rebate from every trade (value extracted from the system at the expense of GMX's treasury, not the pool's assets directly, but represents a conflict of interest)

Hardcoding `bytes32(0)` removes this conflict entirely with no impact on trading functionality. No discount is earned, but no referrer is enriched.

---

## Audit Notes

- All entry points: chain guard → delegatecall guard → owner guard
- No storage declared in adapter (pure delegatecall model)
- Immutables eliminate any storage-collision risk for GMX addresses
- `SafeTransferLib` used for all token operations
- No inline assembly except in upstream library (`VirtualStorageLib`, `StorageLib`)
