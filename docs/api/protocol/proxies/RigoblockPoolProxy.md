# Solidity API

## RigoblockPoolProxy

### _IMPLEMENTATION_SLOT

```solidity
bytes32 _IMPLEMENTATION_SLOT
```

### constructor

```solidity
constructor() public payable
```

Sets address of implementation contract.

### fallback

```solidity
fallback() external payable
```

Fallback function forwards all transactions and returns all received return data.

### ImplementationSlot

```solidity
struct ImplementationSlot {
  address implementation;
}
```

