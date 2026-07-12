# Solidity API

## EscrowFactory

Creates escrow contracts using CREATE2 for deterministic addresses

_Escrow contracts are deployed per pool and operation type_

### EscrowDeployed

```solidity
event EscrowDeployed(address pool, enum OpType opType, address escrowContract)
```

Emitted when a new escrow contract is deployed

### DeploymentFailed

```solidity
error DeploymentFailed()
```

### getEscrowAddress

```solidity
function getEscrowAddress(address pool, enum OpType opType) internal pure returns (address escrowAddress)
```

Gets the deterministic address for an escrow contract

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| pool | address | The pool address |
| opType | enum OpType | The operation type |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| escrowAddress | address | The deterministic address |

### deployEscrow

```solidity
function deployEscrow(address pool, enum OpType opType) internal returns (address escrowContract)
```

Deploys an escrow contract using CREATE2 (idempotent)

_MUST be called via delegatecall from pool context (address(this) == pool)_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| pool | address | The pool address |
| opType | enum OpType | The operation type |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| escrowContract | address | The deployed escrow contract address |

