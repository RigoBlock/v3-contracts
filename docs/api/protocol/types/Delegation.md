# Solidity API

## Delegation

Encodes a single delegation add/remove operation.

### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct Delegation {
  address delegated;
  bytes4 selector;
  bool isDelegated;
}
```

