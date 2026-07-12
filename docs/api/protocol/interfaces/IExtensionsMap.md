# Solidity API

## IExtensionsMap

### eApps

```solidity
function eApps() external view returns (address)
```

Returns the address of the applications extension contract.

### eNavView

```solidity
function eNavView() external view returns (address)
```

Returns the address of the navigation view extension contract.

### eOracle

```solidity
function eOracle() external view returns (address)
```

Returns the address of the oracle extension contract

### eUpgrade

```solidity
function eUpgrade() external view returns (address)
```

Returns the address of the upgrade extension contract.

### eCrosschain

```solidity
function eCrosschain() external view returns (address)
```

Returns the address of the cross-chain handler extension contract.

### eGmxCallback

```solidity
function eGmxCallback() external view returns (address)
```

Returns the address of the GMX v2 callback extension contract.

### wrappedNative

```solidity
function wrappedNative() external view returns (address)
```

Returns the address of the wrapped native token.

_It is used for initializing it in the pool implementation immutable storage without passing it in the constructor._

### getExtensionBySelector

```solidity
function getExtensionBySelector(bytes4 selector) external view returns (address extension, bool shouldDelegatecall)
```

Returns the map of an extension's selector.

_Stores all extensions selectors and addresses in its bytecode for gas efficiency._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| selector | bytes4 | Selector of the function signature. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| extension | address | Address of the target extensions. |
| shouldDelegatecall | bool | Boolean if should maintain context of call or not. |

