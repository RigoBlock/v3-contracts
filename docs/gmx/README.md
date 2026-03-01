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

| Component | File | Role |
|-----------|------|------|
| `AGmxV2` | `contracts/protocol/extensions/adapters/AGmxV2.sol` | Adapter: order management |
| `IAGmxV2` | `contracts/protocol/extensions/adapters/interfaces/IAGmxV2.sol` | Adapter interface |
| `EApps` | `contracts/protocol/extensions/EApps.sol` | Extension: per-call position valuation |
| `ENavView` | `contracts/protocol/extensions/ENavView.sol` | Extension: view-only NAV computation |
| `NavView` | `contracts/protocol/libraries/NavView.sol` | Library: NAV calculation helpers |
| `IGmxSynthetics` | `contracts/utils/exchanges/gmx/IGmxSynthetics.sol` | GMX interface definitions |

## Deployed Addresses (Arbitrum One)

| Contract | Address |
|----------|---------|
| ExchangeRouter | `0x1C3fa76e6E1088bCE750f23a5BFcffa1efEF6A41` |
| DataStore | `0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8` |
| Reader | `0x470fbC46bcC0f16532691Df360A07d8Bf5ee0789` |
| Chainlink Price Feed Provider | `0x38B8dB61b724b51e42A88Cb8eC564CD685a0f53B` |
| Referral Storage | `0xe6fab3F0c7199b0d34d7FbE83394fc0e0D06e99d` |

## GMX Interface Source

Interfaces are defined in `contracts/utils/exchanges/gmx/IGmxSynthetics.sol`. The `lib/gmx-synthetics` git submodule (at `lib/gmx-synthetics/`) provides the canonical structs (`Position.Props`, `Market.Props`) imported directly to avoid duplication.

---

For details on NAV accounting, see [nav-accounting.md](./nav-accounting.md).  
For security analysis, see [security.md](./security.md).
