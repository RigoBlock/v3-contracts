# Solidity API

## IERC20

### Transfer

```solidity
event Transfer(address from, address to, uint256 value)
```

Emitted when a token is transferred.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| from | address | Address transferring the tokens. |
| to | address | Address receiving the tokens. |
| value | uint256 | Number of token units. |

### Approval

```solidity
event Approval(address owner, address spender, uint256 value)
```

Emitted when a token holder sets and approval.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| owner | address | Address of the account setting the approval. |
| spender | address | Address of the allowed account. |
| value | uint256 | Number of approved units. |

### transfer

```solidity
function transfer(address to, uint256 value) external returns (bool success)
```

Transfers token from holder to another address.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| to | address | Address to send tokens to. |
| value | uint256 | Number of token units to send. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| success | bool | Bool the transaction was successful. |

### transferFrom

```solidity
function transferFrom(address from, address to, uint256 value) external returns (bool success)
```

Allows spender to transfer tokens from the holder.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| from | address | Address of the token holder. |
| to | address | Address to send tokens to. |
| value | uint256 | Number of units to transfer. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| success | bool | Bool the transaction was successful. |

### approve

```solidity
function approve(address spender, uint256 value) external returns (bool success)
```

Allows a holder to approve a spender.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| spender | address | Address of the token spender. |
| value | uint256 | Number of units to be approved. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| success | bool | Bool the transaction was successful. |

### balanceOf

```solidity
function balanceOf(address who) external view returns (uint256)
```

Returns token balance for an address.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| who | address | Address to query balance for. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | Number of units held. |

### allowance

```solidity
function allowance(address owner, address spender) external view returns (uint256)
```

Returns token allowance of an address to another address.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| owner | address | Address of token hodler. |
| spender | address | Address of the token spender. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | Number of allowed units. |

### decimals

```solidity
function decimals() external view returns (uint8)
```

Returns token decimals.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint8 | Uint8 number of decimals. |

