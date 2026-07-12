# Solidity API

## Authority

### onlyWhitelister

```solidity
modifier onlyWhitelister()
```

### constructor

```solidity
constructor(address newOwner) public
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

### isWhitelister

```solidity
function isWhitelister(address target) public view returns (bool)
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

