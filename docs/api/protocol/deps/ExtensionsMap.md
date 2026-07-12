# Solidity API

## ExtensionsMap

Its deployed address will be different on different chains and change if selectors or mapped addresses change.

### eApps

```solidity
address eApps
```

Returns the address of the applications extension contract.

### eNavView

```solidity
address eNavView
```

Returns the address of the navigation view extension contract.

### eOracle

```solidity
address eOracle
```

Returns the address of the oracle extension contract

### eUpgrade

```solidity
address eUpgrade
```

Returns the address of the upgrade extension contract.

### eCrosschain

```solidity
address eCrosschain
```

Returns the address of the cross-chain handler extension contract.

### eGmxCallback

```solidity
address eGmxCallback
```

Returns the address of the GMX v2 callback extension contract.

### wrappedNative

```solidity
address wrappedNative
```

Returns the address of the wrapped native token.

_It is used for initializing it in the pool implementation immutable storage without passing it in the constructor._

### constructor

```solidity
constructor() public
```

Assumes extensions have been correctly initialized.

_When adding a new app, modify apps type and assert correct params are passed to the constructor._

### getExtensionBySelector

```solidity
function getExtensionBySelector(bytes4 selector) external view returns (address extension, bool shouldDelegatecall)
```

Returns the map of an extension's selector.

_Should be called by pool with delegatecall_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| selector | bytes4 | Selector of the function signature. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| extension | address | Address of the target extensions. |
| shouldDelegatecall | bool | Boolean if should maintain context of call or not. |

