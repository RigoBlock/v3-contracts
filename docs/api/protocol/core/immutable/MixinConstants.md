# Solidity API

## MixinConstants

Constants are copied in the bytecode and not assigned a storage slot, can safely be added to this contract.

_Inheriting from interface is required as we override public variables._

### VERSION

```solidity
string VERSION
```

Returns a string of the pool version.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |

### _ACCEPTED_TOKENS_SLOT

```solidity
bytes32 _ACCEPTED_TOKENS_SLOT
```

### _APPLICATIONS_SLOT

```solidity
bytes32 _APPLICATIONS_SLOT
```

### _OPERATOR_BOOLEAN_SLOT

```solidity
bytes32 _OPERATOR_BOOLEAN_SLOT
```

### _POOL_ACCOUNTS_SLOT

```solidity
bytes32 _POOL_ACCOUNTS_SLOT
```

### _POOL_INIT_SLOT

```solidity
bytes32 _POOL_INIT_SLOT
```

### _POOL_TOKENS_SLOT

```solidity
bytes32 _POOL_TOKENS_SLOT
```

### _POOL_VARIABLES_SLOT

```solidity
bytes32 _POOL_VARIABLES_SLOT
```

### _TOKEN_REGISTRY_SLOT

```solidity
bytes32 _TOKEN_REGISTRY_SLOT
```

### _UNIV4_TOKEN_IDS_SLOT

```solidity
bytes32 _UNIV4_TOKEN_IDS_SLOT
```

### _VIRTUAL_SUPPLY_SLOT

```solidity
bytes32 _VIRTUAL_SUPPLY_SLOT
```

### _DELEGATION_SLOT

```solidity
bytes32 _DELEGATION_SLOT
```

### _GMX_CALLBACK_SLOT

```solidity
bytes32 _GMX_CALLBACK_SLOT
```

### _ZERO_ADDRESS

```solidity
address _ZERO_ADDRESS
```

### _BASE_TOKEN_FLAG

```solidity
address _BASE_TOKEN_FLAG
```

### _FEE_BASE

```solidity
uint16 _FEE_BASE
```

### _MAX_SPREAD

```solidity
uint16 _MAX_SPREAD
```

### _DEFAULT_SPREAD

```solidity
uint16 _DEFAULT_SPREAD
```

### _MAX_TRANSACTION_FEE

```solidity
uint16 _MAX_TRANSACTION_FEE
```

### _MINIMUM_ORDER_DIVISOR

```solidity
uint16 _MINIMUM_ORDER_DIVISOR
```

### _SPREAD_BASE

```solidity
uint16 _SPREAD_BASE
```

### _MAX_LOCKUP

```solidity
uint48 _MAX_LOCKUP
```

### _MIN_LOCKUP

```solidity
uint48 _MIN_LOCKUP
```

