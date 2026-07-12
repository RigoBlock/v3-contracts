# Solidity API

## MixinInitializer

### BaseTokenDecimals

```solidity
error BaseTokenDecimals()
```

### PoolAlreadyInitialized

```solidity
error PoolAlreadyInitialized()
```

### onlyUninitialized

```solidity
modifier onlyUninitialized()
```

### initializePool

```solidity
function initializePool() external
```

Initializes to pool storage.

_Cannot be reentered as no non-view call is performed to external contracts. Unlocked is kept for backwards compatibility._

