# Solidity API

## IENavView

Provides view methods to retrieve token balances and NAV without modifying state

_Designed for off-chain queries like DeFiLlama, subgraphs, or ZK proof generation_

### getNavDataView

```solidity
function getNavDataView() external view returns (struct NavView.NavData navData)
```

Returns complete NAV data for the pool

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| navData | struct NavView.NavData | Struct containing totalValue, unitaryValue, and timestamp |

### getAppTokensAndBalancesView

```solidity
function getAppTokensAndBalancesView() external view returns (struct AppTokenBalance[] apps)
```

Returns application token balances for external positions

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| apps | struct AppTokenBalance[] | Array of AppTokenBalance structs with balances |

