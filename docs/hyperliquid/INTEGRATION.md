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

HyperCore state lags HyperEVM writes by at least one block. `HyperliquidLib` records an in-flight USDC adjustment on deposits and a cumulative same-block `SPOT_SEND` counter on withdrawals so NAV is not understated or overcommitted during the settlement gap.

To protect against transacting against a stale HyperCore snapshot, any NAV-sensitive operation is deferred for a short time window after a deposit into HyperCore or a spot-send withdrawal back to HyperEVM. The window is defined by `HyperliquidLib._INFLIGHT_WINDOW` and is enforced on-chain in `_updateNav()`, which reads `StorageLib.hyperliquidData().lastActionTimestamp` and reverts with `NavLocked()` if the most recent deposit or withdrawal is still within the window. Perp trading actions (limit orders, cancels, USD-class transfers) do not trigger the lock, because they do not move funds between HyperCore and the EVM-side pool wallet.

Operators and users should still avoid relying on same-block NAV for economically consequential operations, because HyperCore settlement can remain stale into the next block even after the on-chain guard expires.

## Limit orders and same-block fills

Limit orders are forwarded as-is to CoreWriter and recorded with a zero in-flight adjustment. Marketable limit orders that fill immediately can change the Core account value before the precompile view reflects the fill. As with deposits and withdrawals, NAV-sensitive operations should wait for HyperCore settlement.

## Bridge gas reserve

`SPOT_SEND` keeps a small USDC buffer in the Core spot account to pay the spot->EVM bridge fee.

## EOracle on HyperEVM

HyperEVM does not have a deployed Rigoblock BackGeoOracle / Uniswap V4 hook, so `EOracle` is deployed with a zero/dummy oracle address. `EOracle.hasPriceFeed` is the single source of truth for whether a token can be priced on a chain:

- On HyperEVM, `EOracle.hasPriceFeed(token)` returns `true` **only** for `USDC` (`HLConstants.usdc()`).
- It returns `false` for native currency (`address(0)`), wrapped native (`WHYPE`), and every other token.

This behavior is intentional and defines the Hyperliquid integration as **USDC-only**. It is not a bug, and it must not be "fixed" to return `true` for additional tokens.

### Consequences of the USDC-only feed

Any operation that triggers a NAV update — including `mint`, `burn`, cross-chain transfers (`donate`/ECrosschain), and owner NAV reads — will revert if the pool needs a price feed for a non-USDC token. Specifically:

- The pool's **base token** must be USDC. `MixinPoolValue._updateNav` asserts `IEOracle.hasPriceFeed(baseToken)` before computing NAV; on HyperEVM this assertion is equivalent to `baseToken == USDC`.
- The pool can only own/track **USDC** as an active asset. `EnumerableSet.addUnique` and the application balance logic use `hasPriceFeed` to decide which tokens can enter the active set; non-USDC tokens are rejected.
- `AHyperliquid` only accepts **USDC** deposits into HyperCore (`destinationDex = 0` and `token == HLConstants.USDC_TOKEN_INDEX`).

In short: on HyperEVM, **USDC is the only valid base token, ownable token, and HyperCore deposit token**. Pools or operations that require pricing for any other token will revert by design.

## References

- [`AHyperliquid.sol`](../../contracts/protocol/extensions/adapters/AHyperliquid.sol)
- [`HyperliquidLib.sol`](../../contracts/protocol/libraries/HyperliquidLib.sol)
- [Hyperliquid CoreWriter docs](https://docs.chainstack.com/docs/hyperliquid-corewriter)
