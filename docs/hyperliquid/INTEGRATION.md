# Hyperliquid Integration

The Rigoblock Hyperliquid adapter (`AHyperliquid`) exposes the canonical `ICoreWriter` and `ICoreDepositWallet` interfaces so Rigoblock smart pools can interact with Hyperliquid Core as a **USDC-only perps account**.

## Deposit flow

Deposits are routed straight to the Core perp dex via `CoreDepositWallet.deposit(..., destinationDex = 0)`. The adapter only accepts `destinationDex == 0`; spot deposits are rejected because the pool has no price feed for Hyperliquid spot markets and only manages USDC.

## Withdrawal flow

Withdrawing back to HyperEVM is operator-driven and necessarily touches the Core spot account:

1. Move USDC from Core perp margin to Core spot with `USD_CLASS_TRANSFER(toPerp = false)`.
2. Bridge from Core spot to HyperEVM with `SPOT_SEND` targeting the USDC system address.

There is no direct perp-to-EVM bridge in CoreWriter, so both steps are required. Spot-to-perp transfers (`toPerp = true`) are rejected because the adapter is perps-only and does not track spot balances as active NAV tokens.

## Asset restrictions

- Only core perp assets (`assetId < 10_000`) are accepted for limit orders and cancels.
- Outcome markets (`assetId >= 100_000_000`) are rejected. See [`OUTCOME_MARKETS.md`](./OUTCOME_MARKETS.md) for the saved reference implementation and why it was deferred.
- Only USDC (`HLConstants.USDC_TOKEN_INDEX`) is allowed for spot sends.

## NAV / settlement gap

HyperCore state lags HyperEVM writes by at least one block. `HyperliquidLib` records an in-flight USDC adjustment on deposits and a cumulative same-block `SPOT_SEND` counter on withdrawals. The in-flight adjustment is added to the Core balance only when querying the same composite block as the deposit. The `SPOT_SEND` counter is used only inside `_spotSend` to prevent withdrawing more than the available Core spot balance in a single block; it is not subtracted from NAV, so withdrawals do not deflate the pool value while HyperCore settles.

To protect against transacting against a stale HyperCore snapshot, any NAV-sensitive operation is deferred for a settlement window after a deposit into HyperCore or a spot-send withdrawal back to HyperEVM. The window is defined by `HyperliquidLib._SETTLEMENT_WINDOW` (128 seconds). On-chain NAV writes reach the locked `HyperliquidLib.getHyperliquidBalances()`, which calls `HyperliquidLib._assertNavUnlocked()` and reverts with `NavLocked()` if the most recent deposit or withdrawal is still within the window. Off-chain views reach `HyperliquidLib.getHyperliquidBalancesUnsafe()`, which reads the same Core balances without reverting. Because the Hyperliquid balance path is only reached when the `HYPERLIQUID` application bit is active, there is no extra bitmap check inside the library and the lock costs nothing on chains where Hyperliquid is not active. Perp trading actions (limit orders, cancels, USD-class transfers) do not trigger the lock, because they do not move funds between HyperCore and the EVM-side pool wallet.

### Why 128 seconds?

The Hyperliquid adapter calls themselves (`deposit`, `_transferUsdClass`, `_spotSend`) are small, well under the 3M gas small-block limit, so they do not need to land in a big block. The 128-second window is not chosen because of the adapter transaction's gas; it is chosen to cover the time during which a subsequent NAV-sensitive operation may need a big block and during which HyperCore state may still be stale. HyperEVM produces small blocks roughly every 1 second and big blocks roughly every 60 seconds. HyperCore state updates can lag behind EVM writes by more than one small block: CoreWriter actions that move spot/USDC value are documented as delayed "a few seconds," and deposits that miss the next small block may need to wait for a subsequent big block to be reflected in the read precompiles. A NAV read that batches many active applications or a complex oracle update can also exceed the small-block gas limit and land in a big block. A 60-second window would cover approximately one big-block cadence, but it would not comfortably cover the case where an action lands just after a big block starts and settlement plus the next NAV read require the next big block, or where multiple blocks of sequencing/propagation jitter occur. A 128-second window covers more than two full big-block intervals (2 × 60s) plus a small margin, providing a conservative buffer against stale precompile snapshots without being so long that it materially harms normal operation. The value is a policy choice, not a published Hyperliquid SLA; there is no authoritative worst-case precompile-update bound, so the window should be treated as a conservative operational parameter that can be adjusted by a future implementation upgrade if real-world latency data justifies it.

The lock applies to on-chain NAV updates (`MixinPoolValue._updateNav` → `EApps` → `HyperliquidLib.getHyperliquidBalances`), so mint, burn, cross-chain donation accounting, and the stored unitary value cannot be derived from a stale HyperCore snapshot. Off-chain NAV views (`NavView` / `ENavView.getNavDataView`) use the unsafe balance reader so the nav shield can still read a potentially stale NAV and enforce its own policy. Off-chain agents that need to know whether the settlement window is open can read the `lastActionTimestamp` field in `HyperliquidData` directly from the pool storage slot and compare it to the current `block.timestamp`.

Operators and users should still avoid relying on same-block NAV for economically consequential operations, because HyperCore settlement can remain stale into the next block even after the on-chain guard expires.

### External transfers and the lock

The settlement lock is armed only by calls to the Hyperliquid adapter (`AHyperliquid.deposit` and `AHyperliquid.sendRawAction` with `SPOT_SEND`). An external party cannot arm the lock by sending tokens directly to the pool, because that action never writes `lastActionTimestamp`. Therefore an external transfer cannot freeze mint/burn or trigger `NavLocked()`.

Likewise, the same-block in-flight amount is only adjusted by the adapter. An external USDC transfer into the pool is simply reflected in the pool wallet balance on the next NAV update (after the lock expires, if any). It does not interfere with Hyperliquid's internal accounting.

## Limit orders and same-block fills

Limit orders are forwarded as-is to CoreWriter and recorded with a zero in-flight adjustment. Marketable limit orders that fill immediately can change the Core account value before the precompile view reflects the fill. As with deposits and withdrawals, NAV-sensitive operations should wait for HyperCore settlement.

## Bridge gas reserve

`SPOT_SEND` keeps a small USDC buffer in the Core spot account to pay the spot->EVM bridge fee.

## EOracle on HyperEVM

HyperEVM does not have a deployed Rigoblock BackGeoOracle / Uniswap V4 hook, so `EOracle` is deployed with a zero/dummy oracle address. `EOracle.hasPriceFeed` is the single source of truth for whether a token can be priced on a chain:

- On HyperEVM, `EOracle.hasPriceFeed(token)` returns `true` **only** for `USDC` (`HLConstants.usdc()`).
- It returns `false` for native currency (`address(0)`), wrapped native (`WHYPE`), and every other token.

This behavior is intentional and defines the Hyperliquid integration as **USDC-only**. It is not a bug, and it must not be "fixed" to return `true` for additional tokens.

A related invariant holds in `EOracle.convertTokenAmount` / `convertBatchTokenAmounts`: **identity conversions (amount == 0 or token == targetToken) never consult the oracle**, and the target TWAP is computed lazily, only when a batch element actually requires conversion. This is what allows USDC-denominated flows (e.g. cross-chain `donate` finalization, where USDC is converted to the USDC base token) to work on HyperEVM despite the absent oracle. Non-identity conversions still revert, as they should: there is genuinely no feed.

### Consequences of the USDC-only feed

Any operation that triggers a NAV update — including `mint`, `burn`, cross-chain transfers (`donate`/ECrosschain), and owner NAV reads — will revert if the pool needs a price feed for a non-USDC token. Specifically:

- The pool's **base token** must be USDC. `MixinPoolValue._updateNav` asserts `IEOracle.hasPriceFeed(baseToken)` before computing NAV; on HyperEVM this assertion is equivalent to `baseToken == USDC`.
- The pool can only own/track **USDC** as an active asset. `EnumerableSet.addUnique` and the application balance logic use `hasPriceFeed` to decide which tokens can enter the active set; non-USDC tokens are rejected.
- `AHyperliquid` only accepts **USDC** deposits into HyperCore (`destinationDex = 0` and `token == HLConstants.USDC_TOKEN_INDEX`).

In short: on HyperEVM, **USDC is the only valid base token, ownable token, and HyperCore deposit token**. Pools or operations that require pricing for any other token will revert by design.

## Deployment and verification on HyperEVM

HyperEVM uses a dual-block architecture: small blocks every ~1 second with a 3M gas limit, and big blocks every 60 seconds with a 30M gas limit. There is no Hardhat gas-price flag that forces a transaction into a big block; the deployer address itself must have the HyperCore user flag `usingBigBlocks: true` so that the sequencer selects the big-block mempool for its transactions.

The deploy pipeline now attempts to enable this flag automatically. When running on HyperEVM, `src/deploy/deploy_extensions.ts` calls `enableHyperEVMBigBlocks()` (`src/utils/hyperliquid.ts`), which signs and submits the `evmUserModify` action to the Hyperliquid exchange API. If the action succeeds, the deployer is configured for big blocks and standard `yarn deploy --network hyperliquid` / `yarn hardhat verify --network hyperliquid` work without any manual step.

### Prerequisite: deployer must be a HyperCore user

The `evmUserModify` action can only be submitted by an existing HyperCore user. For an EOA, this means the address must have received a Core asset (e.g. USDC) on HyperCore at least once. If the automatic call fails with a "user does not exist" error, fund the deployer address on HyperCore before retrying. You can also run the helper task manually:

```bash
yarn hardhat hyperliquid:enable-big-blocks --network hyperliquid
# testnet:
yarn hardhat hyperliquid:enable-big-blocks --network hyperliquid --testnet
```

For details on the dual-block mechanism, see the [HyperEVM dual-block architecture docs](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/dual-block-architecture).

## References

- [`AHyperliquid.sol`](../../contracts/protocol/extensions/adapters/AHyperliquid.sol)
- [`HyperliquidLib.sol`](../../contracts/protocol/libraries/HyperliquidLib.sol)
- [`MixinPoolValue.sol`](../../contracts/protocol/core/state/MixinPoolValue.sol)
- [HyperEVM dual-block architecture](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/dual-block-architecture)
- [HyperEVM interaction timings](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interaction-timings)
- [Hyperliquid CoreWriter docs](https://docs.chainstack.com/docs/hyperliquid-corewriter)
