# Solidity API

## AIntents

This adapter enables Rigoblock smart pools to bridge tokens across chains while maintaining NAV integrity.

_Uses synchronized adapter deployment to ensure destination adapters exist before enabling cross-chain features._

### NavToleranceTooHigh

```solidity
error NavToleranceTooHigh()
```

### onlyDelegateCall

```solidity
modifier onlyDelegateCall()
```

### requiredVersion

```solidity
function requiredVersion() external pure returns (string)
```

Returns the minimum implementation version to use an external application.

_Adapters must implement it when modifying proxy state or storage._

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | string | String of the minimum supported version. |

### constructor

```solidity
constructor(address acrossSpokePoolAddress) public
```

### depositV3

```solidity
function depositV3(struct IAIntents.AcrossParams params) external
```

Executes a crosschain token transfer to across and updated virtual storage.

_Has different method selector than across depositV3 to avoid viaIr compilation._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| params | struct IAIntents.AcrossParams | Across params encoded as tuple. |

