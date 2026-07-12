# Solidity API

## GmxLib

### ARBITRUM_CHAIN_ID

```solidity
uint256 ARBITRUM_CHAIN_ID
```

### WRAPPED_NATIVE

```solidity
address WRAPPED_NATIVE
```

### GMX_ROUTER

```solidity
contract IGmxExchangeRouter GMX_ROUTER
```

### _GMX_READER

```solidity
address _GMX_READER
```

### _GMX_DATA_STORE

```solidity
address _GMX_DATA_STORE
```

### _GMX_ROLE_STORE

```solidity
address _GMX_ROLE_STORE
```

### MaxGmxPositionsReached

```solidity
error MaxGmxPositionsReached()
```

### TokenPrice

```solidity
struct TokenPrice {
  address token;
  struct Price.Props price;
}
```

### computeExecutionFee

```solidity
function computeExecutionFee(bool isIncrease, uint256 callbackGasLimit) internal view returns (uint256)
```

### getPnlToken

```solidity
function getPnlToken(address market, bool isLong) internal view returns (address)
```

### assertPositionLimitNotReached

```solidity
function assertPositionLimitNotReached(address account, address market, address collateralToken, bool isLong) internal view
```

### getGmxPositionBalances

```solidity
function getGmxPositionBalances(address account) internal view returns (struct AppTokenBalance[] balances)
```

### isMarketActive

```solidity
function isMarketActive(address account, address market) internal view returns (bool)
```

### hasClaimableFundingFees

```solidity
function hasClaimableFundingFees(address account, address market) internal view returns (bool)
```

### claimableCollateralAmount

```solidity
function claimableCollateralAmount(bytes32 amountKey, address account) internal view returns (uint256)
```

