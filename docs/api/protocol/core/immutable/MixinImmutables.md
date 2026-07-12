# Solidity API

## MixinImmutables

Immutables are not assigned a storage slot, can be safely added to this contract.

### InvalidAuthorityInput

```solidity
error InvalidAuthorityInput()
```

### InvalidExtensionsMapInput

```solidity
error InvalidExtensionsMapInput()
```

### authority

```solidity
address authority
```

Returns the address of the authority contract.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |

### wrappedNative

```solidity
address wrappedNative
```

Returns the address of the WETH9 contract.

_Used to convert WETH balances to ETH without executing an oracle call._

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |

### tokenJar

```solidity
address tokenJar
```

Returns the address of the Rigoblock token jar contract.

_Used to transfer protocol fees to the buy-back-and-burn contract._

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |

### _implementation

```solidity
address _implementation
```

### _extensionsMap

```solidity
contract IExtensionsMap _extensionsMap
```

### constructor

```solidity
constructor(address _authority, address extensionsMap, address _tokenJar) internal
```

The ExtensionsMap interface is required to implement the expected methods as sanity check.

