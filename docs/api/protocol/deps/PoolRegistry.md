# Solidity API

## PoolRegistry

### authority

```solidity
address authority
```

Returns the address of the Rigoblock authority contract.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |

### rigoblockDao

```solidity
address rigoblockDao
```

Returns the address of the Rigoblock Dao.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |

### onlyWhitelistedFactory

```solidity
modifier onlyWhitelistedFactory()
```

### onlyPoolOperator

```solidity
modifier onlyPoolOperator(address pool)
```

### onlyRigoblockDao

```solidity
modifier onlyRigoblockDao()
```

### whenAddressFree

```solidity
modifier whenAddressFree(address pool)
```

### whenPoolRegistered

```solidity
modifier whenPoolRegistered(address pool)
```

### constructor

```solidity
constructor(address newAuthority, address newRigoblockDao) public
```

### register

```solidity
function register(address pool, string name, string symbol, bytes32 poolId) external
```

Allows a factory which is an authority to register a pool.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| pool | address | Address of the pool. |
| name | string | String name of the pool (31 characters/bytes or less). |
| symbol | string | String symbol of the pool (3 to 5 characters/bytes). |
| poolId | bytes32 | Bytes32 of the pool id. |

### setAuthority

```solidity
function setAuthority(address newAuthority) external
```

Allows Rigoblock governance to update authority.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| newAuthority | address |  |

### setMeta

```solidity
function setMeta(address pool, bytes32 key, bytes32 value) external
```

Allows pool owner to set metadata for a pool.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| pool | address | Address of the pool. |
| key | bytes32 | Bytes32 of the key. |
| value | bytes32 | Bytes32 of the value. |

### setRigoblockDao

```solidity
function setRigoblockDao(address newRigoblockDao) external
```

Allows Rigoblock Dao to update its address.

_Creates internal record._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| newRigoblockDao | address | Address of the Rigoblock Dao. |

### getPoolIdFromAddress

```solidity
function getPoolIdFromAddress(address pool) external view returns (bytes32 poolId)
```

Returns the id of a pool from its address.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| pool | address | Address of the pool. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| poolId | bytes32 | bytes32 id of the pool. |

### getMeta

```solidity
function getMeta(address pool, bytes32 key) external view returns (bytes32 poolMeta)
```

Returns metadata for a given pool.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| pool | address | Address of the pool. |
| key | bytes32 | Bytes32 key. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| poolMeta | bytes32 | Meta by key. |

### _assertValidNameAndSymbol

```solidity
function _assertValidNameAndSymbol(string name, string symbol) internal pure
```

