# Solidity API

## StorageSlot

### AddressSlot

```solidity
struct AddressSlot {
  address value;
}
```

### getAddressSlot

```solidity
function getAddressSlot(bytes32 slot) internal pure returns (struct StorageSlot.AddressSlot r)
```

