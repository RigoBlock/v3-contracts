# Hyperliquid Integration

The Rigoblock Hyperliquid adapter (`AHyperliquid`) exposes the canonical `ICoreWriter` and `ICoreDepositWallet` interfaces so Rigoblock smart pools can interact with Hyperliquid Core as a **USDC-only perps account**.

## Deposit flow

Deposits are routed straight to the Core perp dex via `CoreDepositWallet.deposit(..., destinationDex = 0)`. The adapter only accepts `destinationDex == 0`; spot deposits are rejected because the pool has no price feed for Hyperliquid spot markets and only manages USDC.

## Withdrawal flow

Withdrawing back to HyperEVM is operator-driven and necessarily touches the Core spot account:

1. Move USDC from Core perp margin to Core spot with `USD_CLASS_TRANSFER(toPerp = false)`.
2. Bridge from Core spot to HyperEVM with `SPOT_SEND` targeting the USDC system address.

There is no direct perp-to-EVM bridge in CoreWriter, so both steps are required.

## Asset restrictions

- Only core perp assets (`assetId < 10_000`) are accepted for limit orders and cancels.
- Outcome markets (`assetId >= 100_000_000`) are rejected. See [`OUTCOME_MARKETS.md`](./OUTCOME_MARKETS.md) for the saved reference implementation and why it was deferred.
- Only USDC (`HLConstants.USDC_TOKEN_INDEX`) is allowed for spot sends.

## NAV / settlement gap

HyperCore state lags HyperEVM writes by at least one block. `HyperliquidLib` records an in-flight USDC adjustment on every state-affecting action so NAV is not understated during the settlement gap. A cumulative same-block `SPOT_SEND` counter prevents multiple withdrawal requests from exceeding the available Core spot balance while the precompile view is stale.

## Bridge gas reserve

`SPOT_SEND` keeps a small USDC buffer in the Core spot account to pay the spot->EVM bridge fee.

## References

- [`AHyperliquid.sol`](../../contracts/protocol/extensions/adapters/AHyperliquid.sol)
- [`HyperliquidLib.sol`](../../contracts/protocol/libraries/HyperliquidLib.sol)
- [Hyperliquid CoreWriter docs](https://docs.chainstack.com/docs/hyperliquid-corewriter)
