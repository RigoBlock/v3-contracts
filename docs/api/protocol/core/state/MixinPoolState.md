# Solidity API

## MixinPoolState

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

_Grg staking is always queried regardless of the active bit._

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| packedApplications | uint256 | Packed value of bitmap encoded active flags. |

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

### getUserAccount

```solidity
function getUserAccount(address who) external view returns (struct ISmartPoolState.UserAccount)
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

### totalSupply

```solidity
function totalSupply() external view returns (uint256)
```

Returns the total amount of issued tokens for this pool.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | Number of total issued tokens. |

### decimals

```solidity
function decimals() public view returns (uint8)
```

### getPool

```solidity
function getPool() public view returns (struct ISmartPoolState.ReturnedPool)
```

Returns the struct containing pool initialization parameters.

_Symbol is stored as bytes8 but returned as string in the returned struct, unlocked is omitted as alwasy true._

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct ISmartPoolState.ReturnedPool | ReturnedPool struct. |

### getPoolParams

```solidity
function getPoolParams() public view returns (struct ISmartPoolState.PoolParams)
```

Returns the struct compaining pool parameters.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct ISmartPoolState.PoolParams | PoolParams struct. |

### getPoolTokens

```solidity
function getPoolTokens() public view returns (struct ISmartPoolState.PoolTokens)
```

Returns the struct containing pool tokens info.
Unitary value is the last stored unitary value.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct ISmartPoolState.PoolTokens | PoolTokens struct. |

### symbol

```solidity
function symbol() public view returns (string)
```

Returns a string of the pool symbol.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | string | String of the symbol. |

### isOperator

```solidity
function isOperator(address holder, address operator) public view returns (bool)
```

### getDelegatedAddresses

```solidity
function getDelegatedAddresses(bytes4 selector) external view returns (address[])
```

Returns all addresses currently granted delegated write access to a selector.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| selector | bytes4 | The adapter function selector to query. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address[] |  |

### getDelegatedSelectors

```solidity
function getDelegatedSelectors(address delegated) external view returns (bytes4[])
```

Returns all selectors currently delegated to an address.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| delegated | address | The address to query. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bytes4[] |  |

### _getActiveApplications

```solidity
function _getActiveApplications() internal view returns (uint256)
```

virtual methods

### _getFeeCollector

```solidity
function _getFeeCollector() internal view returns (address)
```

### _getMinPeriod

```solidity
function _getMinPeriod() internal view returns (uint48)
```

### _getSpread

```solidity
function _getSpread() internal view returns (uint16)
```

_Returns the spread, or _MAX_SPREAD if not set_

### _getTokenJar

```solidity
function _getTokenJar() internal view returns (address)
```

