# Solidity API

## MixinActions

### BaseTokenBalance

```solidity
error BaseTokenBalance()
```

### NativeCurrencyNotAccepted

```solidity
error NativeCurrencyNotAccepted()
```

### PoolAmountSmallerThanMinimum

```solidity
error PoolAmountSmallerThanMinimum(uint16 minimumOrderDivisor)
```

### PoolBurnNotEnough

```solidity
error PoolBurnNotEnough()
```

### PoolBurnNullAmount

```solidity
error PoolBurnNullAmount()
```

### PoolBurnOutputAmount

```solidity
error PoolBurnOutputAmount()
```

### PoolCallerNotWhitelisted

```solidity
error PoolCallerNotWhitelisted()
```

### PoolMinimumPeriodNotEnough

```solidity
error PoolMinimumPeriodNotEnough()
```

### PoolMintAmountIn

```solidity
error PoolMintAmountIn()
```

### PoolMintInvalidRecipient

```solidity
error PoolMintInvalidRecipient()
```

### PoolMintOutputAmount

```solidity
error PoolMintOutputAmount()
```

### PoolTokenNotActive

```solidity
error PoolTokenNotActive()
```

### InvalidOperator

```solidity
error InvalidOperator()
```

### PoolMintTokenNotActive

```solidity
error PoolMintTokenNotActive()
```

### mint

```solidity
function mint(address recipient, uint256 amountIn, uint256 amountOutMin) external payable returns (uint256 recipientAmount)
```

Allows a user to mint pool tokens on behalf of an address.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| recipient | address | Address receiving the tokens. |
| amountIn | uint256 | Amount of base tokens. |
| amountOutMin | uint256 | Minimum amount to be received, prevents pool operator frontrunning. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| recipientAmount | uint256 | Number of tokens minted to recipient. |

### mintWithToken

```solidity
function mintWithToken(address recipient, uint256 amountIn, uint256 amountOutMin, address tokenIn) external payable returns (uint256 recipientAmount)
```

Allows a user to mint pool tokens on behalf of an address using a desired token.

_The token must be vault-owned, i.e. in the active token list, after operator action._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| recipient | address | Address receiving the tokens. |
| amountIn | uint256 | Amount of base tokens. |
| amountOutMin | uint256 | Minimum amount to be received, prevents pool operator frontrunning. |
| tokenIn | address |  |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| recipientAmount | uint256 | Number of tokens minted to recipient. |

### burn

```solidity
function burn(uint256 amountIn, uint256 amountOutMin) external returns (uint256 netRevenue)
```

Allows a pool holder to burn pool tokens.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| amountIn | uint256 | Number of tokens to burn. |
| amountOutMin | uint256 | Minimum amount to be received, prevents pool operator frontrunning. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| netRevenue | uint256 | Net amount of burnt pool tokens. |

### burnForToken

```solidity
function burnForToken(uint256 amountIn, uint256 amountOutMin, address tokenOut) external returns (uint256 netRevenue)
```

Allows a pool holder to burn pool tokens and receive a token other than base token.

_The method is a fallback for when the vault does not hold enough base token, reverts otherwise._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| amountIn | uint256 | Number of tokens to burn. |
| amountOutMin | uint256 | Minimum amount to be received, prevents pool operator frontrunning. |
| tokenOut | address | The token to be received in exchange for pool tokens. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| netRevenue | uint256 | Net amount of burnt pool tokens. |

### updateUnitaryValue

```solidity
function updateUnitaryValue() external returns (struct NetAssetsValue navParams)
```

Allows anyone to store an up-to-date pool price.

_Reentrancy protection provided by calling functions (mint, burn, depositV3, donate)_

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| navParams | struct NetAssetsValue | Tuple of unitary value, net total value, net total liabilities. |

### setOperator

```solidity
function setOperator(address operator, bool approved) external returns (bool)
```

Sets or removes an operator for the caller.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| operator | address | The address of the operator. |
| approved | bool | The approval status. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | bool True, always. |

### decimals

```solidity
function decimals() public view virtual returns (uint8)
```

Returns token decimals.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint8 | Uint8 number of decimals. |

### isOperator

```solidity
function isOperator(address holder, address operator) public view virtual returns (bool approved)
```

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| holder | address | The address of the holder. |
| operator | address | The address of the operator. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| approved | bool | The approval status. |

### _updateNav

```solidity
function _updateNav() internal virtual returns (struct NavComponents)
```

### _getFeeCollector

```solidity
function _getFeeCollector() internal view virtual returns (address)
```

### _getMinPeriod

```solidity
function _getMinPeriod() internal view virtual returns (uint48)
```

### _getSpread

```solidity
function _getSpread() internal view virtual returns (uint16)
```

_Returns the spread, or _MAX_SPREAD if not set_

### _getTokenJar

```solidity
function _getTokenJar() internal view virtual returns (address)
```

