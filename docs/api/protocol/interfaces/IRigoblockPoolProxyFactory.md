# Solidity API

## IRigoblockPoolProxyFactory

### PoolCreated

```solidity
event PoolCreated(address poolAddress)
```

Emitted when a new pool is created.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| poolAddress | address | Address of the new pool. |

### Upgraded

```solidity
event Upgraded(address implementation)
```

Emitted when a new implementation is set by the Rigoblock Dao.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| implementation | address | Address of the new implementation. |

### RegistryUpgraded

```solidity
event RegistryUpgraded(address registry)
```

Emitted when registry address is upgraded by the Rigoblock Dao.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| registry | address | Address of the new registry. |

### implementation

```solidity
function implementation() external view returns (address)
```

Returns the implementation address for the pool proxies.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Address of the implementation. |

### createPool

```solidity
function createPool(string name, string symbol, address baseToken) external returns (address newPoolAddress, bytes32 poolId)
```

Creates a new Rigoblock pool.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| name | string | String of the name. |
| symbol | string | String of the symbol. |
| baseToken | address | Address of the base token. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| newPoolAddress | address | Address of the new pool. |
| poolId | bytes32 | Id of the new pool. |

### setImplementation

```solidity
function setImplementation(address newImplementation) external
```

Allows Rigoblock Dao to update factory pool implementation.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| newImplementation | address | Address of the new implementation contract. |

### setRegistry

```solidity
function setRegistry(address newRegistry) external
```

Allows owner to update the registry.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| newRegistry | address | Address of the new registry. |

### getRegistry

```solidity
function getRegistry() external view returns (address)
```

Returns the address of the pool registry.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Address of the registry. |

### Parameters

Pool initialization parameters.

```solidity
struct Parameters {
  string name;
  bytes8 symbol;
  address owner;
  address baseToken;
}
```

### parameters

```solidity
function parameters() external view returns (struct IRigoblockPoolProxyFactory.Parameters)
```

Returns the pool initialization parameters at proxy deploy.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct IRigoblockPoolProxyFactory.Parameters | Tuple of the pool parameters. |

