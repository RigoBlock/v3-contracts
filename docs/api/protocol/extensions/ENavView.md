# Solidity API

## ENavView

Provides view methods to retrieve token balances and NAV without modifying state

_Designed as an extension to run via delegatecall in pool context for off-chain queries_

### constructor

```solidity
constructor(struct EAppsParams params) public
```

Constructor stores immutable addresses for chain-specific contracts

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| params | struct EAppsParams | Chain-specific addresses bundled into a single struct. |

### getAppTokensAndBalancesView

```solidity
function getAppTokensAndBalancesView() external view returns (struct AppTokenBalance[] balances)
```

Returns application token balances for external positions

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| balances | struct AppTokenBalance[] |  |

### getNavDataView

```solidity
function getNavDataView() external view returns (struct NavView.NavData navData)
```

Returns complete NAV data for the pool

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| navData | struct NavView.NavData | Struct containing totalValue, unitaryValue, and timestamp |

