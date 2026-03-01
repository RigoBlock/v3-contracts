# GMX v2 NAV Accounting

## Overview

Open GMX perpetual positions must be included in the pool's Net Asset Value (NAV). Because positions are stored in the GMX DataStore (not as ERC-20 tokens), the standard token-based NAV calculation is insufficient. Rigoblock uses a dedicated **active-app gate** plus **Reader calls** to include GMX position value.

## Components

| Component | Responsibility |
|-----------|----------------|
| `EApps` | Per-call position valuation (called by delegates during deposits/withdrawals) |
| `ENavView` | View-only NAV computation including GMX (off-chain queries, multi-call) |
| `NavView` | Shared library: NAV calculation with optional GMX inclusion |
| `IGmxSynthetics` | Interface types: `Position.Props`, `PositionInfo`, `Market.Props`, `MarketPrices` |

## Position Valuation Flow

### 1. Active-App Gate

Before querying GMX, `EApps` checks whether the pool has any GMX activity via `ApplicationsLib`:

```solidity
// ApplicationsLib tracks which external apps are active for this pool.
// The GMX_V2_POSITIONS bit is set the first time createIncreaseOrder is called
// (via StorageLib.activeApplications().storeApplication(GMX_V2_POSITIONS)).
// If the bit is not set, the pool has never had a GMX position and
// GmxLib.getGmxPositionBalances is never invoked — no RPC calls to Arbitrum Reader.
```

This gate is the **primary multi-chain safety boundary**: because `AGmxV2.createIncreaseOrder`
guards its constructor with `GmxLib.ARBITRUM_CHAIN_ID`, the `GMX_V2_POSITIONS` bit is
never set on non-Arbitrum deployments, so `GmxLib` is never called there.

`GmxLib.getGmxPositionBalances` itself intentionally has **no chain-ID guard**.
Adding one would be redundant and would obscure the real guard location (the adapter constructor).

### 2. Fetch Positions

```solidity
Position.Props[] memory positions = IGmxReader(_reader).getAccountPositions(
    _dataStore,
    poolAddress,
    0,
    32   // clamps safely to actual count
);
```

If `positions.length == 0`, valuation returns 0 without hitting `getAccountPositionInfoList`.

### 3. Fetch Markets

Each position references a `market` address. The `getAccountPositionInfoList` call requires `GmxMarketPrices` per market. Current prices are fetched from `GmxLib._safeGetGmxPrice`:

```solidity
// GmxLib uses the hardcoded Chainlink provider constant (Arbitrum One):
// address private constant _GMX_CHAINLINK_PRICE_FEED = 0x38B8dB61...;
GmxValidatedPrice memory validated =
    IGmxChainlinkPriceFeedProvider(_GMX_CHAINLINK_PRICE_FEED).getOraclePrice(token, "");
Price.Props memory price = Price.Props({ min: validated.min, max: validated.max });
```

All GMX addresses (`_GMX_READER`, `_GMX_DATA_STORE`, `_GMX_REFERRAL_STORAGE`,
`_GMX_CHAINLINK_PRICE_FEED`, `_WRAPPED_NATIVE`) are **private constants** in
`GmxLib.sol` — they are NOT threaded through constructor parameters.

### 4. Get Position Info

```solidity
GmxPositionInfo[] memory infos = IGmxReader(_GMX_READER).getAccountPositionInfoList(
    _GMX_DATA_STORE,
    _GMX_REFERRAL_STORAGE,
    account,
    markets,          // address[] per-position market addresses
    marketPrices,     // GmxMarketPrices[] with min/max for index/long/short tokens
    address(0),       // no UI fee receiver
    0,
    type(uint256).max
);
```

Each `PositionInfo` contains:
- `position.numbers.collateralAmount` — deposited collateral
- `fees.funding.claimableLongTokenAmount` — accrued funding fees (long)
- `fees.funding.claimableShortTokenAmount` — accrued funding fees (short)
- `pnlAfterPriceImpact` — unrealised PnL in USD (18 decimals)

### 5. Funding Fee Inclusion

Claimable funding fees are returned as native market tokens — not converted to any common denomination:

```solidity
uint256 cl = posInfo.fees.funding.claimableLongTokenAmount;
if (cl > 0) tmp[count++] = AppTokenBalance({token: mkt.longToken, amount: int256(cl)});
uint256 cs = posInfo.fees.funding.claimableShortTokenAmount;
if (cs > 0) tmp[count++] = AppTokenBalance({token: mkt.shortToken, amount: int256(cs)});
```

NavView prices each token via `EOracle.convertTokenAmount` using the pool's standard Chainlink feeds.

### 6. Aggregate Value — Native Token Design

`GmxLib` returns **native collateral tokens** in `AppTokenBalance[]`:

```solidity
address colToken = posInfo.position.addresses.collateralToken;
int256 net = _computeGmxNetCollateral(posInfo);
if (net > 0) tmp[count++] = AppTokenBalance({token: colToken, amount: net});
```

**Why native tokens?**

1. **Purge protection is implicit**: a USDC-collateral position returns `{token: USDC, amount: net}`. When `EApps` reports USDC with a positive amount, `purgeInactiveTokensAndApps` finds `inApp = true` for USDC and does not remove it from `activeTokensSet`. A WETH-conversion approach breaks this: USDC never appears in `EApps` output → wallet balance 0 during open position → USDC gets purged → returned collateral invisible to NAV.
2. **No double-conversion error**: NavView already converts each `AppTokenBalance` to the pool's base token via `EOracle.convertTokenAmount`. Converting to WETH first, then to base token, introduces an additional step with no benefit.
3. **Simplicity**: ~60 lines of conversion math eliminated.

`_WRAPPED_NATIVE` is only used by `_safeGetGmxPrice` (to build `GmxMarketPrices` for the Reader call) and is not present in the returned balances.

## Address Constants (Arbitrum One)

All GMX addresses are **private constants** inside `GmxLib`:

```solidity
uint256 internal constant ARBITRUM_CHAIN_ID          = 42161;
address private  constant _GMX_READER                = 0x470fbC46bcC0f16532691Df360A07d8Bf5ee0789;
address private  constant _GMX_DATA_STORE            = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;
address private  constant _GMX_REFERRAL_STORAGE      = 0xe6fab3F0c7199b0d34d7FbE83394fc0e0D06e99d;
address private  constant _GMX_CHAINLINK_PRICE_FEED  = 0x38B8dB61b724b51e42A88Cb8eC564CD685a0f53B;
address private  constant _WRAPPED_NATIVE            = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH
```

`ARBITRUM_CHAIN_ID` is `internal` so `AGmxV2` (the adapter) can import it from
`GmxLib` instead of maintaining its own copy.

`ENavView` constructor now takes **only 2 parameters**: `grgStakingProxy` and
`univ4Posm` — GMX addresses are embedded in `GmxLib` constants, not threaded
through constructors. The old `GmxParams` struct in `NavView` has been removed.

## EApps vs ENavView

| | `EApps` | `ENavView` |
|---|---|---|
| Called by | Pool during mint/redeem | Off-chain via staticcall |
| Execution context | delegatecall from pool | delegatecall from pool |
| Purpose | Include GMX value in deposit/withdrawal NAV | Read-only NAV snapshot |
| Gas sensitivity | High (must be cheap for users) | Low (view only) |
| Chain guard | none (activation gate is sufficient) | none (same) |
| Active-app gate | ✅ | ✅ |

## Zero-Position Fast Path

If the pool has no open GMX positions:

1. `activeApps & GMX_V2_POSITIONS == 0` → skip entirely (no RPC call)
2. OR positions array length == 0 → returns 0 without `getAccountPositionInfoList`

Both paths ensure GMX queries add negligible overhead to pools with no activity.

## Staleness Handling

GMX position data inherits Chainlink oracle staleness. `IGmxChainlinkPriceFeedProvider.getOraclePrice(token, "")` delegates to the configured Chainlink aggregator; no additional freshness check is applied inside `GmxLib`. Production usage should ensure Chainlink feeds are live.

`GmxLib._safeGetGmxPrice` wraps the call in a `try/catch` — if the oracle reverts (paused, feed removed, etc.) it returns a zero `Price.Props`, which causes the position to be valued at zero collateral only (conservative fallback via `_collateralOnlyBalances`).

## Negative Net Position Value

`_computeGmxNetCollateral` returns `int256`. It may produce a negative result when the sum of estimated fees (`totalCostAmount`) exceeds the remaining collateral. `_appendGmxPosBalances` floors this to zero:

```solidity
int256 net = _computeGmxNetCollateral(posInfo);
if (net > 0) { /* include in NAV */ }
// if net <= 0: silently skipped — zero contribution
```

**Why this is correct:**

GMX has automatic liquidation and ADL (auto-deleveraging) mechanics that kick in before a position's collateral drops to zero. Before the net value can realistically go negative:
1. The position breaches the minimum collateral ratio → GMX marks it for liquidation.
2. A keeper calls `liquidatePosition` → remaining collateral (minus liquidation fee) is returned to the pool.
3. The pool receives back whatever collateral survived. It cannot owe GMX anything beyond what was deposited.

When `_computeGmxNetCollateral` returns a negative number, it means:
- Our fee estimate is conservative and overshoots actual fees, **or**
- The position is already in the liquidation queue (keepers will execute shortly)

In both cases, reporting **zero** is the correct NAV contribution — not a negative one. The `AppTokenBalance.amount` field is `int256` (capable of expressing negative values), but GmxLib deliberately does not use that capability for position values.

**Note on `AppTokenBalance.amount` being `int256`:** This signed type exists because the broader NAV infrastructure uses `convertBatchTokenAmounts` which accepts signed amounts (supporting the virtual supply cross-chain model). A negative wallet balance is semantically meaningful there; a negative GMX position value is not.

## Collateral Token Tracking Design

**Normal flow:**

1. Pool owner swaps ETH → USDC via `AUniswap` / `A0xRouter`
2. The swap adapter calls `_trackToken(USDC)` on token arrival → USDC enters `activeTokensSet`
3. Pool owner calls `createIncreaseOrder` with USDC collateral
4. `createIncreaseOrder` calls `_trackToken(params.initialCollateralToken)` — no-op if already tracked; ensures tracking if token arrived via direct transfer (bypassing swap adapters)
5. USDC leaves pool wallet → GMX OrderVault → position opened in DataStore
6. **While open**: `GmxLib` returns `{token: USDC, amount: net}` via `EApps` → USDC found `inApp` → purge protection active → NAV correct
7. Pool owner calls `createDecreaseOrder` → position executed → USDC returns to pool wallet
8. USDC is in `activeTokensSet` → wallet balance counted in NAV ✓

**Why `createIncreaseOrder` ALWAYS calls `_trackToken`:**

GMX closes positions via keeper execution, which sends collateral back to the pool wallet WITHOUT calling back into the adapter. Open time is the only reliable hook to ensure the collateral token is tracked. If the token arrived via a swap adapter it is already tracked (`_trackToken` is a no-op); if it arrived via direct external transfer, `_trackToken` adds it at open time so the returned collateral is visible after close.

## Known NAV Coverage Gaps

Two GMX accounting scenarios produce a **temporary NAV undercount** until the pool owner takes a manual action. In both cases the missing value is conservative (never an overstatement) and the assets are not lost — they remain claimable from the GMX DataStore.

---

### Gap 1 — Price-Impact Rebate Collateral

When a decrease order executes with a sufficiently large negative price impact, GMX withholds a portion of the collateral as a rebate that becomes claimable over time (see [GMX docs — Price Impact Rebates](https://docs.gmx.io/docs/trading/v2#price-impact-rebates)). The claimable amount is keyed by `(market, token, timeKey)` where `timeKey = block.timestamp / DATA_STORE.getUint("CLAIMABLE_COLLATERAL_TIME_DIVISOR")`.

**Why `GmxLib` cannot see it automatically:**

`getAccountPositionInfoList` returns data for *open* positions only. The withheld rebate is stored directly in the GMX DataStore under a per-account, per-time-bucket key; it is not reachable via any Reader view that generic position queries exercise.

Receiving notice of a new claimable rebate at order-execution time would require implementing the `afterOrderExecution` GMX keeper callback. The adapter cannot implement this callback because the keeper is not the pool owner — any callback made by the keeper would be routed by `MixinFallback` as a `staticcall` (not a `delegatecall`), so all state writes inside the callback would revert.

**Workaround (current):**

The pool owner computes the `timeKey` off-chain:
```
timeKey = executionTimestamp / DATA_STORE.getUint(keccak256("CLAIMABLE_COLLATERAL_TIME_DIVISOR"))
```
and calls `AGmxV2.claimCollateral(markets, tokens, timeKeys)`. Once claimed, the collateral lands in the pool wallet and is immediately visible to NAV.

**Future option:** A dedicated GMX callback extension (`EGmxCallback`) could receive `afterOrderExecution` from the keeper. The extension would be delegatecalled for all callers (extensions are always delegatecalled regardless of `msg.sender`), so the keeper could trigger a state write. The extension must restrict `msg.sender` to the GMX role-store controller to prevent arbitrary callers from manipulating stored claimable-collateral keys. This extension is **not currently implemented** — the workaround is acceptable given the rarity of high-price-impact decreases.

---

### Gap 2 — Accrued Funding Fees After Full Position Close

`GmxLib._appendGmxPosBalances` reads `positionInfo.fees.funding.claimableLongTokenAmount` and `claimableShortTokenAmount` from `getAccountPositionInfoList`, which only returns **open** positions. Once the last position on a given market is closed, any unclaimed funding fees that were accruing on that market become invisible to the NAV loop: the `PositionInfo` no longer exists in the Reader response, and the claimable-funding-amount DataStore keys are not queried anywhere.

The amounts remain claimable at:
```
keccak256(abi.encode("CLAIMABLE_FUNDING_AMOUNT", market, token, account))
```

**Impact:** Unclaimed funding fees from a fully-closed market are not reflected in NAV until `AGmxV2.claimFundingFees(markets, tokens)` is called. Funding fee accrual is gradual — the undercount grows slowly and is bounded by the fee rate × position size × time.

**Workaround (current):** The pool owner should call `claimFundingFees` for the relevant markets when closing the last position on that market, or periodically if long-lived positions are held.

**Future option:** The same `EGmxCallback` extension described above could track which markets have ever been active (analogous to maintaining a set of historical markets), enabling the NAV loop to also query closed-market funding fees. This is not currently implemented.

---

### Summary

| Gap | Trigger | Missing value type | How to recover |
|---|---|---|---|
| Price-impact rebate | High-impact decrease execution | Withheld collateral | Call `claimCollateral(markets, tokens, timeKeys)` |
| Post-close funding fees | Full position close on a market | Accrued funding fees | Call `claimFundingFees(markets, tokens)` |

Both actions are already exposed by `AGmxV2`. Neither gap creates an NAV overstatement or an exploitable manipulation vector — the pool can only be undervalued relative to true holdings, never overvalued.

