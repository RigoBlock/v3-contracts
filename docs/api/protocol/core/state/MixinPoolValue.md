# Solidity API

## MixinPoolValue

A contract that retrieves smart pool token balances and computes their base token value.

### BaseTokenPriceFeedError

```solidity
error BaseTokenPriceFeedError()
```

### _updateNav

```solidity
function _updateNav() internal returns (struct NavComponents components)
```

Uses transient storage to keep track of unique token balances.

_With null total supply a pool will return the last stored value._

### _getActiveApplications

```solidity
function _getActiveApplications() internal view virtual returns (uint256)
```

virtual methods

