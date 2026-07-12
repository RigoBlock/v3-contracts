# Solidity API

## ExtensionsMapDeployer

### deployedMaps

```solidity
mapping(address => mapping(bytes32 => address)) deployedMaps
```

Returns the nonce of the deployed ExtensionsMap contract.

_It is increased only when a new contract is deployed._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |

### deployExtensionsMap

```solidity
function deployExtensionsMap(struct DeploymentParams params, bytes32 salt) external returns (address)
```

Returns the address of the deployed contract.

_If the params are unchanged, the address of the already-deployed contract is returned._

### parameters

```solidity
function parameters() external view returns (struct DeploymentParams)
```

Returns the extensions deployment parameters.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct DeploymentParams | Tuple of the deployment parameters '(Extensions, address)'. |

