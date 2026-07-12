# Solidity API

## EOracle

### constructor

```solidity
constructor(address oracleHookAddress, address wrappedNative) public
```

### convertBatchTokenAmounts

```solidity
function convertBatchTokenAmounts(address[] tokens, int256[] amounts, address targetToken) external view returns (int256 totalConvertedAmount)
```

Returns the sum of the token amounts converted to a target token.

_Will first try to convert via cross with chain currency, fallback to direct cross if not available._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| tokens | address[] | The array of token addresses to be converted. |
| amounts | int256[] | The array of amounts to be converted. |
| targetToken | address | The address of the target token. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| totalConvertedAmount | int256 | The total value of converted amount in target token amount. |

### convertTokenAmount

```solidity
function convertTokenAmount(address token, int256 amount, address targetToken) external view returns (int256 convertedAmount)
```

Returns a token amount converted to a target token.

_Will first try to convert via cross with chain currency, fallback to direct cross if not available._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| token | address | The address of the token to be converted. |
| amount | int256 | The amount to be converted. |
| targetToken | address | The address of the target token. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| convertedAmount | int256 | The value of converted amount in target token amount. |

### hasPriceFeed

```solidity
function hasPriceFeed(address token) external view returns (bool)
```

Returns whether a token has a price feed.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| token | address | The address of the token. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | Boolean the price feed exists. |

### getTwap

```solidity
function getTwap(address token) public view returns (int24 twap)
```

Returns token price aginst native currency.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| token | address | The address of the token. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| twap | int24 | The time weighted average price. |

