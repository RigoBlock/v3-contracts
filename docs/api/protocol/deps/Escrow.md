# Solidity API

## Escrow

Manages refunds to pool via escrow, like across expired deposits.

_Deployed per pool per OpType via CREATE2 for deterministic addressing_

### TokensDonated

```solidity
event TokensDonated(address token, uint256 amount)
```

Emitted when tokens are donated back to the pool

### pool

```solidity
address pool
```

The pool this escrow is associated with

### opType

```solidity
enum OpType opType
```

The operation type this escrow handles (Transfer or Sync)

### InvalidAmount

```solidity
error InvalidAmount()
```

### InvalidPool

```solidity
error InvalidPool()
```

### UnsupportedToken

```solidity
error UnsupportedToken()
```

### constructor

```solidity
constructor(address _pool, enum OpType _opType) public
```

_The passed pool must be a Rigoblock pool, i.e. implement `donate` with unlock._

### refundVault

```solidity
function refundVault(address token) external
```

Allows anyone to send owned to the target Rigoblock pool.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| token | address | The token address to claim. |

