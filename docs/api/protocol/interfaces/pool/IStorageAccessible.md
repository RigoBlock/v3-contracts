# Solidity API

## IStorageAccessible

See https://github.com/gnosis/util-contracts/blob/bb5fe5fb5df6d8400998094fb1b32a178a47c3a1/contracts/StorageAccessible.sol

### getStorageAt

```solidity
function getStorageAt(uint256 offset, uint256 length) external view returns (bytes)
```

Reads `length` bytes of storage in the currents contract.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| offset | uint256 | - the offset in the current contract's storage in words to start reading from. |
| length | uint256 | - the number of words (32 bytes) of data to read. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bytes | Bytes string of the bytes that were read. |

### getStorageSlotsAt

```solidity
function getStorageSlotsAt(uint256[] slots) external view returns (bytes)
```

Reads bytes of storage at different storage locations.

_Returns a string with values regarless of where they are stored, i.e. variable, mapping or struct._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| slots | uint256[] | The array of storage slots to query into. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bytes | Bytes string composite of different storage locations' value. |

