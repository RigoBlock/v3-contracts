# Solidity API

## IEUpgrade

### Upgraded

```solidity
event Upgraded(address implementation)
```

Emitted when pool operator upgrades proxy implementation address.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| implementation | address | Address of the new implementation. |

### upgradeImplementation

```solidity
function upgradeImplementation() external
```

Allows caller to upgrade pool implementation.

_Cannot be called directly and in pool is restricted to pool owner._

### getBeacon

```solidity
function getBeacon() external view returns (address)
```

Returns the implementation beacon.
Address of the beacon.

