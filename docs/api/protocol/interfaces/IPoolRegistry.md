# Solidity API

## IPoolRegistry

### PoolMeta

Mapping of pool meta by pool key.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct PoolMeta {
  mapping(bytes32 => bytes32) meta;
}
```

### AuthorityChanged

```solidity
event AuthorityChanged(address authority)
```

Emitted when Rigoblock Dao updates authority address.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| authority | address | Address of the new authority contract. |

### MetaChanged

```solidity
event MetaChanged(address pool, bytes32 key, bytes32 value)
```

Emitted when pool owner updates meta data for its pool.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| pool | address | Address of the pool. |
| key | bytes32 | Bytes32 key for indexing. |
| value | bytes32 | Bytes32 of the value associated with the key. |

### Registered

```solidity
event Registered(address group, address pool, bytes32 name, bytes32 symbol, bytes32 id)
```

Emitted when a new pool is registered in registry.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| group | address | Address of the pool factory. |
| pool | address | Address of the registered pool. |
| name | bytes32 | String name of the pool. |
| symbol | bytes32 | String name of the pool. |
| id | bytes32 | Bytes32 id of the pool. |

### RigoblockDaoChanged

```solidity
event RigoblockDaoChanged(address rigoblockDao)
```

Emitted when rigoblock Dao address is updated.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| rigoblockDao | address | New Dao address. |

### authority

```solidity
function authority() external view returns (address)
```

Returns the address of the Rigoblock authority contract.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Address of the authority contract. |

### rigoblockDao

```solidity
function rigoblockDao() external view returns (address)
```

Returns the address of the Rigoblock Dao.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Address of the Rigoblock Dao. |

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
function setAuthority(address authority) external
```

Allows Rigoblock governance to update authority.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| authority | address | Address of the authority contract. |

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

