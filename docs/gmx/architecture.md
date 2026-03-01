# GMX v2 Adapter — Architecture

## Design Constraints

`AGmxV2` is a **stateless adapter** executed via `delegatecall` from the pool proxy. This means:

- **No storage variables** — all state lives in the pool's storage via `StorageLib`
- **Immutable constructor params** — chain-specific addresses stored as `immutable` to avoid storage
- **`onlyDelegateCall` modifier** — reverts if called directly (not via delegatecall)
- **Pool is the token vault** — collateral is held in the pool until an order is submitted

```solidity
// All canonical addresses are constants in GmxLib (no constructor params needed):
address internal constant GMX_EXCHANGE_ROUTER = 0x1C3fa76...;  // in GmxLib.sol
address internal constant WRAPPED_NATIVE = 0x82aF49...;         // WETH on Arbitrum
address private constant _GMX_READER = 0x470fbC...;
address private constant _GMX_DATA_STORE = 0xFD70de...;
uint256 internal constant ARBITRUM_CHAIN_ID = 42161;

// Delegatecall guard (the only immutable in AGmxV2):
address private immutable _adapter;  // = address(this) at deploy time
```

## Order Flow

### Create Increase Order

```
1. Pool owner calls createIncreaseOrder(params)
2. Adapter validates:
   - `MixinFallback` routes call via `delegatecall` only if `msg.sender == pool().owner`; non-owners are `staticcall`ed
   - position count < 32 (GmxLib.MaxGmxPositionsReached)
   - computedFee <= 0.05 ETH (ExecutionFeeExceedsMax)
3. Transfer collateral to GMX OrderVault:
   - if collateral == WETH: transfer (initialCollateral + executionFee) WETH
   - if collateral != WETH: transfer collateral + transfer executionFee WETH separately
4. Call ExchangeRouter.createOrder(params) → returns orderKey (bytes32)
5. GMX keeper executes at next oracle update → position opened in DataStore
```

### Execution Fee Auto-Computation

All three order entry points (`createIncreaseOrder`, `createDecreaseOrder`, `updateOrder`) compute the execution fee on-chain via `GmxLib.computeExecutionFee`. No fee parameter is required from callers.

```
fee = adjustedGasLimit × tx.gasprice
adjustedGasLimit = baseGasLimit + 3×perOracleGas + applyFactor(orderGasLimit, multiplier)
```

All four inputs are read from the GMX DataStore at execution time (block-constant within a tx). This matches the formula in `GasUtils.adjustGasLimitForEstimate` and passes `validateExecutionFee` exactly.

**`updateOrder` always tops up with the increase-order gas limit** (the larger of the two order types) regardless of the actual order being updated. Any excess beyond what the keeper needs is refunded by GMX to `cancellationReceiver` (the pool) after execution.

**Safety cap**: `executionFee <= _MAX_EXECUTION_FEE (0.05 ETH)` guards against extreme gas price spikes. At typical Arbitrum rates (<0.1 gwei), the real fee is ~0.0002 ETH.

**eth_call simulations**: `tx.gasprice = 0` in simulations means fee = 0 and WETH consumption is understated. Actual on-chain execution is always correct — the pool only needs sufficient combined ETH+WETH for the real fee.

### Cancel Order

GMX enforces a `REQUEST_EXPIRATION_TIME = 300 seconds` delay before a user can cancel an order. Attempting to cancel before this window results in `RequestNotYetCancellable`. This is a protocol-level constraint read from DataStore:

```
keccak256(abi.encode("REQUEST_EXPIRATION_TIME")) → 300 (seconds)
```

### Claim Collateral

`claimCollateral` reverts (arithmetic underflow panic in deployed contract) when nothing is claimable. Callers should only invoke this when they know collateral is available (e.g., after a failed order execution). Attempting to claim zero results in a revert from the ExchangeRouter.

### Update Order

Only **limit orders** can be updated (`LimitIncrease`, `LimitDecrease`, `StopLossDecrease`). Calling `updateOrder` on a `MarketIncrease` or `MarketDecrease` order results in:

```
OrderNotUpdatable(uint256 orderType)
```

This is a GMX protocol constraint, not an adapter limitation.

## Position Storage

GMX positions are **not ERC-20 tokens**. They are stored as structs in the GMX `DataStore` keyed by:

```
positionKey = keccak256(abi.encode(account, market, collateralToken, isLong))
```

Positions are retrieved via:

```solidity
IGmxReader(_reader).getAccountPositions(
    _dataStore,
    address(this),   // pool is the account
    0,
    _MAX_GMX_POSITIONS   // 32
)
```

`EnumerableValues.valuesAt(start, end)` in the deployed Reader **clamps `end` to the actual array length**, so requesting `end = 32` on an account with 2 positions safely returns 2 positions.

Note: `getAccountPositionCount` is an internal library function (`PositionStoreUtils`) and is **not exposed** by the deployed Reader contract. Always use `getAccountPositions(...).length` instead.

## Token Tracking

`_trackToken(initialCollateralToken)` is called at `createIncreaseOrder` time. This registers the collateral token in the pool's active-tokens set so it is visible to NAV computation when the position is eventually settled (keeper sends collateral + PnL to the pool as ERC-20 tokens).

**Why `decreasePositionSwapType` is forced to `NoSwap`:**

GMX's `decreasePositionSwapType` controls implicit output swaps during position settlement:

| Value | Output token |
|---|---|
| `NoSwap` | Collateral token (what was used to open) |
| `SwapPnlTokenToCollateralToken` | Collateral token (PnL index token swapped to collateral) |
| `SwapCollateralTokenToPnlToken` | **Market index token** (e.g. WETH on ETH/USD) |

If `SwapCollateralTokenToPnlToken` were allowed, the settlement output would be the market's index/long token — a token we have no `_trackToken` record for — making it permanently invisible to NAV. The adapter forces `decreasePositionSwapType: NoSwap` so the output is always the collateral token already in the active-tokens set.

WETH (`GmxLib.WRAPPED_NATIVE`) is excluded from `_trackToken` because the pool's base token or oracle handles it separately.

## Position Limit

The adapter enforces a maximum of 32 concurrent GMX positions per pool (`_MAX_GMX_POSITIONS`). This is checked before every `createIncreaseOrder`:

```solidity
function _assertPositionLimitNotReached() private view {
    require(
        _reader.getAccountPositions(_dataStore, address(this), 0, _MAX_GMX_POSITIONS).length
            < _MAX_GMX_POSITIONS,
        MaxGmxPositionsReached()
    );
}
```

## Chain Guard

The adapter registers a `chainId = 42161` (Arbitrum One) guard. Any attempt to use the GMX adapter on a non-Arbitrum chain reverts with `NotArbitrum`:

```solidity
// GmxLib exports the canonical value; AGmxV2 imports it instead of duplicating.
uint256 internal constant ARBITRUM_CHAIN_ID = 42161;  // in GmxLib.sol

// AGmxV2 constructor — checked ONCE at deployment:
require(block.chainid == GmxLib.ARBITRUM_CHAIN_ID, NotArbitrum());
```

The guard lives **only in the constructor**, not on individual entry points.
This is correct by design:
- The adapter is deployed as an immutable contract at a fixed address.
- The constructor check proves the adapter was deployed on Arbitrum.
- Individual entry points are protected by `onlyDelegateCall` (no direct calls)
  and by the pool's Authority routing (only registered on Arbitrum Authority).

The **real multi-chain boundary** is the app-activation gate in `EApps`/`GmxLib`:
because `GMX_V2_POSITIONS` is only set when `createIncreaseOrder` runs (which
requires the adapter to be deployed and registered in Authority), pools on
non-Arbitrum chains never have this bit set and `GmxLib` is never invoked.
## Active Application Tracking

When a position is created, GMX is registered as an **active application** in the pool's app registry:

```solidity
// In AGmxV2.createIncreaseOrder, after the order is submitted:
StorageLib.activeApplications().storeApplication(uint256(Applications.GMX_V2_POSITIONS));
```

This bit is checked by `EApps` before calling `GmxLib.getGmxPositionBalances`.
If the bit is not set, `GmxLib` is never called — no Arbitrum Reader RPC, no
Chainlink price lookups. This is the layer that makes GMX queries free for pools
that have never opened a GMX position.

## Token Tracking

Rigoblock's protocol rule: tokens are added to `activeTokensSet` when they
**enter** the pool (via `StorageLib.activeTokensSet().addUnique(...)`), not when
they leave.

**`createIncreaseOrder` ALWAYS calls `_trackToken`** on the collateral token.
Although tokens are canonically tracked when they enter the pool, a token can sit
in the pool wallet without being in `activeTokensSet` if it arrived via a direct
external transfer rather than a swap adapter. GMX closes positions via keeper
execution, which sends collateral back to the pool wallet WITHOUT calling back
into the adapter. Open time is the only reliable hook — if we omit `_trackToken`
here, an externally-transferred collateral token stays invisible to wallet NAV
after position close.

For tokens that arrived via a swap adapter, `_trackToken` is a no-op (already
tracked). The call is always safe.

## Referral Code

All orders pass `referralCode: bytes32(0)` to GMX — no referral code is accepted or stored.

Accepting a referral code as a constructor parameter would allow the pool operator to register their own code and earn GMX token rebates from every pool trade (conflict of interest — rebate goes to the operator's EOA, not the pool). Hardcoding `bytes32(0)` eliminates this with no impact on trading functionality. See `docs/gmx/security.md` for full analysis.

## Common Pitfalls

These are GMX-specific pitfalls discovered during implementation.
General adapter pitfalls live in AGENTS.md.

1. **`ARBITRUM_CHAIN_ID` lives in `GmxLib`** — `GmxLib.ARBITRUM_CHAIN_ID` is `internal` — the single canonical constant. `AGmxV2` imports it from `GmxLib`. Never define a duplicate `_ARBITRUM_CHAIN_ID` in the adapter or elsewhere.

2. **No chain-ID guard in `GmxLib.getGmxPositionBalances`** — The real guard is the app-activation bit (`GMX_V2_POSITIONS`), set only via `AGmxV2.createIncreaseOrder`, which is constructor-guarded to Arbitrum. A `block.chainid` check inside `GmxLib` is redundant and hides the real guard. Do not add one.

3. **Always call `_trackToken` on collateral in `createIncreaseOrder`** — See Token Tracking section above. The call is idempotent for normal flows and essential for the external-transfer edge case.

4. **Realized P&L tests require mocking oracle BEFORE `_executeOrder`** — `_executeOrder` routes to Chainlink then calls the keeper. Mock the Chainlink price feed BEFORE calling `_executeOrder` so the keeper executes at the mocked price. `_executeOrder` calls `vm.clearMockedCalls()` at the end — cleanup is automatic. Mocking only for the `updateUnitaryValue` call after close validates NAV display, not that any profit was actually realized.

5. **Negative net position value is floored at zero** — `_computeGmxNetCollateral` may return a negative `int256` when estimated fees exceed deposited collateral. `_appendGmxPosBalances` drops these (`if (net > 0)`). This is correct: GMX v2 guarantees the pool can never owe more than its deposited collateral. A negative computed value means the position is in the liquidation queue; flooring at zero is a slight understatement (never an overstatement) of recovery. Never propagate the negative value.

6. **`GmxLib` returns native collateral tokens, not WETH** — Balances are `{token: collateralToken, amount: net}`. This makes purge protection implicit (USDC appears in `EApps` output → `purgeInactiveTokensAndApps` finds `inApp = true` → USDC not removed). See `docs/gmx/nav-accounting.md` for full explanation.
