# BackGeoOracle — Rigoblock On-Chain Price Feeds

## What It Is

BackGeoOracle is a Uniswap V4 hook that provides manipulation-resistant, on-chain price feeds for token pairs. It is the canonical oracle system used by Rigoblock smart pools for:

- Real-time NAV calculations
- Swap Shield price checks
- Cross-chain transfer valuation
- GMX position pricing

The oracle is deployed as a **single pool per token pair** (`fee = 0`, `tickSpacing = MAX_TICK_SPACING`, full-range liquidity) with an attached hook contract that records price observations and defends against manipulation via automatic backrunning and per-block tick truncation.

> **Repository**: https://github.com/RigoBlock/back-geo-oracle  
> **Docs**: https://docs.rigoblock.com/oracles-and-price-feeds

---

## Architecture

### Hook Overview

The hook implements the following V4 hook callbacks:

| Callback | Purpose |
|----------|---------|
| `beforeInitialize` | Enforces `fee = 0` and `tickSpacing = TickMath.MAX_TICK_SPACING` (one oracle pool per pair) |
| `afterInitialize` | Initializes the observation array (cardinality tracking) |
| `beforeAddLiquidity` | Enforces full-range positions only; updates the pool observation |
| `beforeRemoveLiquidity` | Updates the pool observation |
| `beforeSwap` | Only `exactInput` swaps are allowed; updates the pool observation |
| `afterSwap` | Executes backrun logic if price moved beyond the safe threshold |

### Key Mechanisms

#### 1. Truncated Geometric Mean (Per-Block Cap)

The oracle caps the tick delta between consecutive blocks to limit manipulation speed. Even if an attacker pushes the pool price aggressively, the oracle observation only records a bounded move per block. The exact cap is configured in the hook and is derived from the `MAX_ABS_TICK_MOVE` constant in the truncated-oracle logic.

#### 2. Automatic Backrunning

When a swap causes a large price move, the hook triggers a backrun in `afterSwap`:

- The hook mints ERC-6909 tokens to the original swap sender.
- It executes an inverse swap that pushes the price back toward the pre-swap level.
- This makes single-block manipulation unprofitable because the attacker must absorb the backrun cost.

> **Important**: Swap routers interacting with the oracle pool **must implement `IMsgSender.msgSender()`** so the hook knows where to credit backrun tokens. If the router does not expose this method, transactions that trigger a backrun will revert.

#### 3. Observation Storage

The hook maintains an array of `Observation` structs per pool (indexed by `PoolId`):

```solidity
struct Observation {
    uint32 blockTimestamp;
    int24 prevTick;
    int48 tickCumulative;
    uint144 secondsPerLiquidityCumulativeX128;
}
```

Observations are written on the **first state-modifying action of each block** (add/remove liquidity or swap), ensuring the recorded price is captured before any in-block manipulation.

#### 4. Cardinality & TWAP Windows

- `cardinality` is the number of stored observations.
- New pools start with `cardinality = 1`.
- Operators should call `increaseCardinalityNext()` to raise the target cardinality (higher = more robust TWAP).
- Rigoblock's `EOracle` queries a **5-minute TWAP** (or the maximum available window if cardinality is smaller).

---

## Protocol Integration (`EOracle`)

Rigoblock pools do not call the hook directly. They interact with the **`EOracle`** extension, which wraps the hook in a friendly API:

```solidity
contract EOracle is IEOracle {
    function getTwap(address token) public view returns (int24 twap);
    function convertTokenAmount(address token, int256 amount, address targetToken) external view returns (int256);
    function hasPriceFeed(address token) external view returns (bool);
    function convertBatchTokenAmounts(address[] calldata tokens, int256[] calldata amounts, address targetToken)
        external view returns (int256 totalConvertedAmount);
}
```

### Price Feed Registration

A token is considered to have an active price feed when the oracle pool's `cardinality > 0` (i.e., it has been initialized and has at least one observation). `hasPriceFeed()` returns `true` for:

- `address(0)` (native currency)
- The chain's wrapped native token (WETH, WMATIC, etc.)
- Any token whose oracle pool has `cardinality > 0`

### TWAP Calculation

`EOracle.getTwap()` reads the oracle's `observe()` method with a two-point window:

```solidity
uint32[] memory secondsAgos = _getSecondsAgos(state.cardinality);
(int48[] memory tickCumulatives, ) = _oracle.observe(key, secondsAgos);
return int24((tickCumulatives[1] - tickCumulatives[0]) / int56(int32(secondsAgos[0])));
```

The window is:
- **300 seconds** (5 minutes) if cardinality is large enough
- Otherwise `cardinality * blockTime` (1s on L2s, 8s on Ethereum)

The returned tick is converted to a price via `TickMath.getSqrtPriceAtTick()` inside `convertTokenAmount()`.

### Cross-Price Routing

If the pool needs to convert `tokenA → tokenB` and no direct oracle pool exists, `EOracle` uses ETH as the hub:

```
tokenA → ETH (getTwap(tokenA))
ETH → tokenB (getTwap(tokenB))
conversionTick = -(twapA - twapB)
```

If the resulting tick is outside `MIN_TICK..MAX_TICK`, the conversion returns `0` (conservative fallback).

---

## Security Model

### Manipulation Cost

- **Single-block attacks**: Backrun logic makes these unprofitable; the attacker loses the backrun spread.
- **Multi-block attacks**: Possible in theory, but require sustaining large capital at risk across many blocks while arbitragers extract value. The truncated-per-block cap means meaningful manipulation takes many blocks.
- **Low-liquidity pools**: Full-range liquidity in oracle pools ensures there is always some depth, but operators should monitor cardinality and ensure active arbitrage.

### Known Limitations

1. **Oracle staleness**: Like any TWAP, the price lags the spot market. Rigoblock's Swap Shield uses this to its advantage — it blocks DEX quotes that deviate too far from the oracle.
2. **Cardinality = 1**: A pool with only one observation is effectively a spot oracle. Always increase cardinality before relying on a feed for high-value operations.
3. **Router compatibility**: Routers that do not implement `IMsgSender` will cause reverts on backrun-triggering swaps.
4. **Native currency mapping**: `address(0)` is used as the sentinel for native currency inside `EOracle`. The hook itself uses `address(0)` as `currency0` for ETH/token pools.

---

## Deployment Checklist

When deploying a new BackGeoOracle price feed:

1. **Initialize the pool** via the Uniswap V4 `PoolManager` with:
   - `fee = 0`
   - `tickSpacing = TickMath.MAX_TICK_SPACING`
   - `hooks = BackGeoOracle(address)`
2. **Provide full-range liquidity** (any other range will revert).
3. **Call `increaseCardinalityNext()`** to raise observations (recommend at least `60` for 1-minute granularity or `300` for 1-second chains).
4. **Verify the feed** by calling `observe()` and checking that the returned cumulative ticks advance each block.

---

## References

- **BackGeoOracle source**: https://github.com/RigoBlock/back-geo-oracle
- **Uniswap V4 Hooks docs**: https://docs.uniswap.org/contracts/v4/overview
- **Audit**: `audits/33Audits_audit_back_geo_oracle.pdf` in the back-geo-oracle repository
- **Rigoblock oracle docs**: https://docs.rigoblock.com/oracles-and-price-feeds
