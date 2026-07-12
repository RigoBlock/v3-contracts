# Solidity API

## ISmartPoolState

### getAcceptedMintTokens

```solidity
function getAcceptedMintTokens() external view returns (address[] tokens)
```

Returns the list of accepted mint tokens.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| tokens | address[] | Array of token addresses. |

### getActiveApplications

```solidity
function getActiveApplications() external view returns (uint256 packedApplications)
```

Returns the active application flags.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| packedApplications | uint256 | Packed value of bitmap encoded active flags. |

### ActiveTokens

```solidity
struct ActiveTokens {
  address[] activeTokens;
  address baseToken;
}
```

### getActiveTokens

```solidity
function getActiveTokens() external view returns (struct ISmartPoolState.ActiveTokens tokens)
```

Returns the list of active tokens and the base token.

_Base token is always active._

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| tokens | struct ISmartPoolState.ActiveTokens | Tuple of active tokens list and base token. |

### ReturnedPool

Returned pool initialization parameters.

_Symbol is stored as bytes8 but returned as string to facilitating client view._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct ReturnedPool {
  string name;
  string symbol;
  uint8 decimals;
  address owner;
  address baseToken;
}
```

### getPool

```solidity
function getPool() external view returns (struct ISmartPoolState.ReturnedPool)
```

Returns the struct containing pool initialization parameters.

_Symbol is stored as bytes8 but returned as string in the returned struct, unlocked is omitted as alwasy true._

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct ISmartPoolState.ReturnedPool | ReturnedPool struct. |

### PoolParams

Pool variables.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct PoolParams {
  uint48 minPeriod;
  uint16 spread;
  uint16 transactionFee;
  address feeCollector;
  address kycProvider;
}
```

### getPoolParams

```solidity
function getPoolParams() external view returns (struct ISmartPoolState.PoolParams)
```

Returns the struct compaining pool parameters.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct ISmartPoolState.PoolParams | PoolParams struct. |

### PoolTokens

Pool tokens.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct PoolTokens {
  uint256 unitaryValue;
  uint256 totalSupply;
}
```

### getPoolTokens

```solidity
function getPoolTokens() external view returns (struct ISmartPoolState.PoolTokens)
```

Returns the struct containing pool tokens info.
Unitary value is the last stored unitary value.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct ISmartPoolState.PoolTokens | PoolTokens struct. |

### getPoolStorage

```solidity
function getPoolStorage() external view returns (struct ISmartPoolState.ReturnedPool poolInitParams, struct ISmartPoolState.PoolParams poolVariables, struct ISmartPoolState.PoolTokens poolTokensInfo)
```

Returns the aggregate pool generic storage.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| poolInitParams | struct ISmartPoolState.ReturnedPool | The pool's initialization parameters. |
| poolVariables | struct ISmartPoolState.PoolParams | The pool's variables. |
| poolTokensInfo | struct ISmartPoolState.PoolTokens | The pool's tokens info. |

### UserAccount

Pool holder account.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct UserAccount {
  uint208 userBalance;
  uint48 activation;
}
```

### getUserAccount

```solidity
function getUserAccount(address _who) external view returns (struct ISmartPoolState.UserAccount)
```

Returns a pool holder's account struct.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct ISmartPoolState.UserAccount | UserAccount struct. |

### name

```solidity
function name() external view returns (string)
```

Returns a string of the pool name.

_Name maximum length 31 bytes._

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | string | String of the name. |

### owner

```solidity
function owner() external view returns (address)
```

Returns the address of the owner.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Address of the owner. |

### symbol

```solidity
function symbol() external view returns (string)
```

Returns a string of the pool symbol.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | string | String of the symbol. |

### totalSupply

```solidity
function totalSupply() external view returns (uint256)
```

Returns the total amount of issued tokens for this pool.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | Number of total issued tokens. |

### isOperator

```solidity
function isOperator(address holder, address operator) external view returns (bool approved)
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

### getDelegatedAddresses

```solidity
function getDelegatedAddresses(bytes4 selector) external view returns (address[] addresses)
```

Returns all addresses currently granted delegated write access to a selector.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| selector | bytes4 | The adapter function selector to query. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| addresses | address[] | Array of addresses with delegated access for that selector. |

### getDelegatedSelectors

```solidity
function getDelegatedSelectors(address delegated) external view returns (bytes4[] selectors)
```

Returns all selectors currently delegated to an address.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| delegated | address | The address to query. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| selectors | bytes4[] | Array of selectors the address has been granted access to. |

