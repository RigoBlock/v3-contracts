# Solidity API

## ISmartPoolActions

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

