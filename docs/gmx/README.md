# GMX v2 Perpetuals Integration

This directory documents the GMX v2 perpetuals adapter integration with the Rigoblock Smart Pool protocol.

## Overview

The GMX v2 integration allows Rigoblock pool owners to trade perpetual futures via the GMX v2 DEX on **Arbitrum One only** (`chainId = 42161`). Positions are opened through an **adapter** pattern — the pool's collateral stays in the pool until an order is submitted, and GMX handles keeper execution.

## Architecture

```
Pool Owner → SmartPool.fallback()
              ↓ delegatecall (via Authority adapter registry)
           AGmxV2.createIncreaseOrder()
              ↓ direct call
           GMX ExchangeRouter.createOrder()
              ↓ transfers collateral to OrderVault
           [GMX Keeper executes order at next oracle update]
              ↓ position opened
           GMX DataStore stores position key
              ↓ EApps.getAppTokenBalances() queries
           GMX Reader.getAccountPositions() → NAV inclusion
```

## Key Components

| Component        | File                                                            | Role                                   |
| ---------------- | --------------------------------------------------------------- | -------------------------------------- |
| `AGmxV2`         | `contracts/protocol/extensions/adapters/AGmxV2.sol`             | Adapter: order management              |
| `IAGmxV2`        | `contracts/protocol/extensions/adapters/interfaces/IAGmxV2.sol` | Adapter interface                      |
| `EApps`          | `contracts/protocol/extensions/EApps.sol`                       | Extension: per-call position valuation |
| `ENavView`       | `contracts/protocol/extensions/ENavView.sol`                    | Extension: view-only NAV computation   |
| `NavView`        | `contracts/protocol/libraries/NavView.sol`                      | Library: NAV calculation helpers       |
| `gmx-synthetics` | `lib/gmx-synthetics/` (pinned submodule)                        | All GMX types and contract interfaces  |

## Deployed Addresses (Arbitrum One)

| Contract                      | Address                                      |
| ----------------------------- | -------------------------------------------- |
| ExchangeRouter                | `0x7dE39FF2e232A2203196788d37e234cF8F1b83f1` |
| DataStore                     | `0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8` |
| Reader                        | `0xfA26cBb46e2614609406de08CA1Dc7f70a684184` |
| Chainlink Price Feed Provider | `0x90218fbb064b1475E4382b041Cc7ccF08AF718B0` |
| Referral Storage              | `0xe6fab3F0c7199b0d34d7FbE83394fc0e0D06e99d` |

> **GMX v2.2c rotation (~Sep 15-16 2026):** GMX rotated the ExchangeRouter, Reader,
> OrderHandler (now `0xa5D2d45228ee2E3A18AB122B2cE84997d008f4Eb`, resolved dynamically via
> `ExchangeRouter.orderHandler()`), and ChainlinkPriceFeedProvider. DataStore, RoleStore,
> OrderVault, ReferralStorage, and WETH are unchanged. Always cross-check live addresses
> against GMX's `updates` branch `docs/contracts.json` — the `main` branch lags rotations.

## GMX Interface Source

All GMX types and methods are imported directly from the pinned `lib/gmx-synthetics`
git submodule (e.g. `ReaderPositionUtils.PositionInfo`, `MarketUtils.MarketPrices`,
`ReaderUtils.OrderInfo`, `OracleUtils.ValidatedPrice`, and the concrete `Reader`,
`DataStore`, `RoleStore`, `ExchangeRouter`, `OrderHandler`, `ChainlinkPriceFeedProvider`
contracts cast at the canonical addresses in `GmxConstants.sol`). This guarantees the
ABI decoder can never drift from the deployed GMX contracts.

---

For details on NAV accounting, see [nav-accounting.md](./nav-accounting.md).  
For details on the hardcoded fallback feeds for synthetic index tokens, see
`scripts/gmx/README.md` and the "Fallback Chainlink Feeds" section in
[nav-accounting.md](./nav-accounting.md).  
For security analysis, see [security.md](./security.md).
