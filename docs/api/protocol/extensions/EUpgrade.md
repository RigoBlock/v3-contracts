# Solidity API

## EUpgrade

### EUpgradeDirectCall

```solidity
error EUpgradeDirectCall()
```

### EUpgradeImplementationIsSameAsCurrent

```solidity
error EUpgradeImplementationIsSameAsCurrent()
```

### constructor

```solidity
constructor(address factory) public
```

### upgradeImplementation

```solidity
function upgradeImplementation() external
```

Allows caller to upgrade pool implementation.

_Cannot be called directly and in pool is restricted to pool owner._

### getBeacon

```solidity
function getBeacon() public view returns (address)
```

Returns the implementation beacon.
Address of the beacon.

