# Solidity API

## MixinFallback

### PoolImplementationDirectCallNotAllowed

```solidity
error PoolImplementationDirectCallNotAllowed()
```

### PoolMethodNotAllowed

```solidity
error PoolMethodNotAllowed()
```

### PoolVersionNotSupported

```solidity
error PoolVersionNotSupported()
```

### onlyDelegateCall

```solidity
modifier onlyDelegateCall()
```

### fallback

```solidity
fallback() external
```

Delegate calls to pool extension.

_Extensions are persistent, while adapters are upgradable by the governance.
uses shouldDelegatecall to flag selectors that should prompt a delegatecall._

### receive

```solidity
receive() external payable
```

Allows transfers to pool.

_Prevents accidental transfer to implementation contract._

