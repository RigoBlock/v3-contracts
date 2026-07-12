# Solidity API

## IMinimumVersion

### requiredVersion

```solidity
function requiredVersion() external view returns (string)
```

Returns the minimum implementation version to use an external application.

_Adapters must implement it when modifying proxy state or storage._

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | string | String of the minimum supported version. |

