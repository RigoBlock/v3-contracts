# Solidity API

## IAuthority

### PermissionAdded

```solidity
event PermissionAdded(address from, address target, uint8 permissionType)
```

Adds a permission for a role.

_Possible roles are Role.ADAPTER, Role.FACTORY, Role.WHITELISTER_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| from | address | Address of the method caller. |
| target | address | Address of the approved wallet. |
| permissionType | uint8 | Enum type of permission. |

### PermissionRemoved

```solidity
event PermissionRemoved(address from, address target, uint8 permissionType)
```

Removes a permission for a role.

_Possible roles are Role.ADAPTER, Role.FACTORY, Role.WHITELISTER_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| from | address | Address of the  method caller. |
| target | address | Address of the approved wallet. |
| permissionType | uint8 | Enum type of permission. |

### RemovedMethod

```solidity
event RemovedMethod(address from, address adapter, bytes4 selector)
```

Removes an approved method.

_Removes a mapping of method selector to adapter according to eip1967._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| from | address | Address of the  method caller. |
| adapter | address | Address of the adapter. |
| selector | bytes4 | Bytes4 of the method signature. |

### WhitelistedMethod

```solidity
event WhitelistedMethod(address from, address adapter, bytes4 selector)
```

Approves a new method.

_Adds a mapping of method selector to adapter according to eip1967._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| from | address | Address of the  method caller. |
| adapter | address | Address of the adapter. |
| selector | bytes4 | Bytes4 of the method signature. |

### Role

```solidity
enum Role {
  ADAPTER,
  FACTORY,
  WHITELISTER
}
```

### Permission

Mapping of permission type to bool.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct Permission {
  mapping(enum IAuthority.Role => bool) authorized;
}
```

### addMethod

```solidity
function addMethod(bytes4 selector, address adapter) external
```

Allows a whitelister to whitelist a method.
We do not save list of approved as better queried by events.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| selector | bytes4 | Bytes4 hex of the method selector. |
| adapter | address | Address of the adapter implementing the method. |

### removeMethod

```solidity
function removeMethod(bytes4 selector, address adapter) external
```

Allows a whitelister to remove a method.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| selector | bytes4 | Bytes4 hex of the method selector. |
| adapter | address | Address of the adapter implementing the method. |

### setAdapter

```solidity
function setAdapter(address adapter, bool isWhitelisted) external
```

Allows owner to set extension adapter address.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| adapter | address | Address of the target adapter. |
| isWhitelisted | bool | Bool whitelisted. |

### setFactory

```solidity
function setFactory(address factory, bool isWhitelisted) external
```

Allows an admin to set factory permission.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| factory | address | Address of the target factory. |
| isWhitelisted | bool | Bool whitelisted. |

### setWhitelister

```solidity
function setWhitelister(address whitelister, bool isWhitelisted) external
```

Allows the owner to set whitelister permission.
Whitelister permission is required to approve methods in extensions adapter.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| whitelister | address | Address of the whitelister. |
| isWhitelisted | bool | Bool whitelisted. |

### getApplicationAdapter

```solidity
function getApplicationAdapter(bytes4 selector) external view returns (address)
```

Returns the address of the adapter associated to the signature.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| selector | bytes4 | Hex of the method signature. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Address of the adapter. |

### isWhitelistedFactory

```solidity
function isWhitelistedFactory(address target) external view returns (bool)
```

Provides whether a factory is whitelisted.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| target | address | Address of the target factory. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | Bool is whitelisted. |

### isWhitelister

```solidity
function isWhitelister(address target) external view returns (bool)
```

Provides whether an address is whitelister.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| target | address | Address of the target whitelister. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | Bool is whitelisted. |

