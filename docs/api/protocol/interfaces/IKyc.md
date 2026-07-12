# Solidity API

## IKyc

### isWhitelistedUser

```solidity
function isWhitelistedUser(address user) external view returns (bool)
```

Returns whether an address has been whitelisted.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| user | address | The address to verify. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | Bool the user is whitelisted. |

