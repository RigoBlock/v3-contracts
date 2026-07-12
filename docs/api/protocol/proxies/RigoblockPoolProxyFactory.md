# Solidity API

## RigoblockPoolProxyFactory

### implementation

```solidity
address implementation
```

Returns the implementation address for the pool proxies.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |

### onlyRigoblockDao

```solidity
modifier onlyRigoblockDao()
```

### constructor

```solidity
constructor(address newImplementation, address registry) public
```

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

### parameters

```solidity
function parameters() external view returns (struct IRigoblockPoolProxyFactory.Parameters)
```

Returns the pool initialization parameters at proxy deploy.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct IRigoblockPoolProxyFactory.Parameters | Tuple of the pool parameters. |

### getRegistry

```solidity
function getRegistry() public view returns (address)
```

Returns the address of the pool registry.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Address of the registry. |

### _createPool

```solidity
function _createPool(string name, string symbol, address baseToken) internal returns (bytes32 salt, contract RigoblockPoolProxy newProxy)
```

_Creates a pool and routes to eventful._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| name | string | String of the name. |
| symbol | string | String of the symbol. |
| baseToken | address | Address of the base token. |

