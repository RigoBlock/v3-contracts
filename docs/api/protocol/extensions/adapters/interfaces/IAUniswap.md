# Solidity API

## IAUniswap

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
function unwrapWETH9(uint256 amountMinimum, address recipient) external
```

Unwraps ETH from WETH9.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| amountMinimum | uint256 | The minimum amount of WETH9 to unwrap. |
| recipient | address | The address to keep same uniswap npm selector. |

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

