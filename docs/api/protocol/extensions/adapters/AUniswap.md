# Solidity API

## AUniswap

### constructor

```solidity
constructor(address weth) public
```

### requiredVersion

```solidity
function requiredVersion() external pure returns (string)
```

Returns the minimum implementation version to use an external application.

_Adapters must implement it when modifying proxy state or storage._

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | string | String of the minimum supported version. |

### unwrapWETH9

```solidity
function unwrapWETH9(uint256 amountMinimum) external
```

Unwraps the contract's WETH9 balance and sends it to recipient as ETH.

_The amountMinimum parameter prevents malicious contracts from stealing WETH9 from users._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| amountMinimum | uint256 | The minimum amount of WETH9 to unwrap. |

### unwrapWETH9

```solidity
function unwrapWETH9(uint256 amountMinimum, address) external
```

Unwraps ETH from WETH9.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| amountMinimum | uint256 | The minimum amount of WETH9 to unwrap. |
|  | address |  |

### wrapETH

```solidity
function wrapETH(uint256 value) external
```

Wraps ETH.

_Client must wrap if input is native currency._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| value | uint256 | The ETH amount to be wrapped. |

