# Solidity API

## ApplicationsSlot

```solidity
struct ApplicationsSlot {
  uint256 packedApplications;
}
```

## ApplicationsLib

### ApplicationIndexBitmaskRange

```solidity
error ApplicationIndexBitmaskRange()
```

### storeApplication

```solidity
function storeApplication(struct ApplicationsSlot self, uint256 appIndex) internal
```

Sets an application as active in the bitmask.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| self | struct ApplicationsSlot | The storage slot where the packed applications are stored. |
| appIndex | uint256 | The application to set as active. |

### removeApplication

```solidity
function removeApplication(struct ApplicationsSlot self, uint256 appIndex) internal
```

Removes an application from being active in the bitmask.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| self | struct ApplicationsSlot | The storage slot where the packed applications are stored. |
| appIndex | uint256 | The application to remove. |

### isActiveApplication

```solidity
function isActiveApplication(uint256 packedApplications, uint256 appIndex) internal pure returns (bool)
```

Checks if an application is active in the bitmask.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| packedApplications | uint256 | The bitmap packed active applications flags. |
| appIndex | uint256 | The application to check. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | bool Whether the application is active. |

### shouldQueryApp

```solidity
function shouldQueryApp(uint256 packedApplications, uint256 appIndex) internal pure returns (bool)
```

Returns whether an application should be queried for token balances.

_GRG_STAKING is always queried: it is a pre-existing application that self-activates
 on the first NAV write, so the active-bit may not be set yet on a fresh pool._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| packedApplications | uint256 | The bitmap packed active applications flags. |
| appIndex | uint256 | The application to check. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | bool Whether the application should be queried. |

