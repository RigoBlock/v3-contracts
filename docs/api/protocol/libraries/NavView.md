# Solidity API

## NavView

Provides internal functions to calculate NAV and retrieve application balances

_This library contains the core logic for the ENavView extension_

### OUT_OF_RANGE_FLAG

```solidity
int24 OUT_OF_RANGE_FLAG
```

Flag to identify out-of-range positions in Uniswap V4

### ZERO_ADDRESS

```solidity
address ZERO_ADDRESS
```

### NavData

```solidity
struct NavData {
  uint256 totalValue;
  uint256 unitaryValue;
  uint256 timestamp;
}
```

### getAppTokenBalances

```solidity
function getAppTokenBalances(address pool, address grgStakingProxy, address uniV4Posm) internal view returns (struct AppTokenBalance[] balances)
```

### getNavData

```solidity
function getNavData(address pool, address grgStakingProxy, address uniV4Posm) internal view returns (struct NavView.NavData)
```

