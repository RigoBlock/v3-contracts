# Solidity API

## IExtensionsMapDeployer

### deployedMaps

```solidity
function deployedMaps(address deployer, bytes32 salt) external view returns (address mapAddress)
```

Returns the nonce of the deployed ExtensionsMap contract.

_It is increased only when a new contract is deployed._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| deployer | address | Address of the deployer wallet. |
| salt | bytes32 | Bytes32 input to allow multi-chain deterministic deployment. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| mapAddress | address | Address of the mapped contract. |

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

