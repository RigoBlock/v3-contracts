# Solidity API

## AddressSet

```solidity
struct AddressSet {
  address[] addresses;
  mapping(address => uint256) positions;
}
```

## Bytes32Set

```solidity
struct Bytes32Set {
  bytes32[] values;
  mapping(bytes32 => uint256) positions;
}
```

## Pool

Pool initialization parameters.

_This struct is not visible externally and used to store/read pool init params._

### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct Pool {
  string name;
  bytes8 symbol;
  uint8 decimals;
  address owner;
  bool unlocked;
  address baseToken;
}
```

## EnumerableSet

Adapted from https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/structs/EnumerableSet.sol

### AddressListExceedsMaxLength

```solidity
error AddressListExceedsMaxLength()
```

### TokenPriceFeedDoesNotExist

```solidity
error TokenPriceFeedDoesNotExist(address token)
```

### _MAX_UNIQUE_VALUES

```solidity
uint256 _MAX_UNIQUE_VALUES
```

### addUnique

```solidity
function addUnique(struct AddressSet set, contract IEOracle eOracle, address token, address baseToken) internal returns (bool wasActive)
```

Adds `token` to the set if it is not the base token and not already active.

_Reads set.positions[token] exactly once. Returns whether the token was active
 before this call (base token is always considered active and is never stored)._

### remove

```solidity
function remove(struct AddressSet set, address token) internal
```

### isActive

```solidity
function isActive(struct AddressSet set, address token) internal view returns (bool)
```

### add

```solidity
function add(struct Bytes32Set set, bytes32 value) internal
```

### remove

```solidity
function remove(struct Bytes32Set set, bytes32 value) internal
```

### contains

```solidity
function contains(struct Bytes32Set set, bytes32 value) internal view returns (bool)
```

### length

```solidity
function length(struct Bytes32Set set) internal view returns (uint256)
```

### at

```solidity
function at(struct Bytes32Set set, uint256 index) internal view returns (bytes32)
```

