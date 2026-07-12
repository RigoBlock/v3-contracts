# Solidity API

## IRigoblockV3PoolState

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
function getPool() external view returns (struct IRigoblockV3PoolState.ReturnedPool)
```

Returns the struct containing pool initialization parameters.

_Symbol is stored as bytes8 but returned as string in the returned struct, unlocked is omitted as alwasy true._

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct IRigoblockV3PoolState.ReturnedPool | ReturnedPool struct. |

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
function getPoolParams() external view returns (struct IRigoblockV3PoolState.PoolParams)
```

Returns the struct compaining pool parameters.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct IRigoblockV3PoolState.PoolParams | PoolParams struct. |

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
function getPoolTokens() external view returns (struct IRigoblockV3PoolState.PoolTokens)
```

Returns the struct containing pool tokens info.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct IRigoblockV3PoolState.PoolTokens | PoolTokens struct. |

### getPoolStorage

```solidity
function getPoolStorage() external view returns (struct IRigoblockV3PoolState.ReturnedPool poolInitParams, struct IRigoblockV3PoolState.PoolParams poolVariables, struct IRigoblockV3PoolState.PoolTokens poolTokensInfo)
```

Returns the aggregate pool generic storage.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| poolInitParams | struct IRigoblockV3PoolState.ReturnedPool | The pool's initialization parameters. |
| poolVariables | struct IRigoblockV3PoolState.PoolParams | The pool's variables. |
| poolTokensInfo | struct IRigoblockV3PoolState.PoolTokens | The pool's tokens info. |

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
function getUserAccount(address _who) external view returns (struct IRigoblockV3PoolState.UserAccount)
```

Returns a pool holder's account struct.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct IRigoblockV3PoolState.UserAccount | UserAccount struct. |

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

