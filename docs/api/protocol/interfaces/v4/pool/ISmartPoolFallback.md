# Solidity API

## ISmartPoolFallback

### fallback

```solidity
fallback() external
```

Delegate calls to pool extension.

_Delegatecall restricted to owner, staticcall accessible by everyone.
Restricting delegatecall to owner effectively locks direct calls._

### receive

```solidity
receive() external payable
```

Allows transfers to pool.

_Prevents accidental transfer to implementation contract._

