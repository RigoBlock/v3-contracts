# Solidity API

## SmartPool

### constructor

```solidity
constructor(address authority, address extensionsMap, address tokenJar) public
```

Owner is initialized to 0 to lock owner actions in this implementation.
Kyc provider set as will effectively lock direct mint/burn actions.
ExtensionsMap validation is performed in MixinImmutables constructor.

