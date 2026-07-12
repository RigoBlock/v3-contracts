# Solidity API

## MixinStorage

Storage slots must be preserved to prevent storage clashing.

_Pool storage is not sequential: each variable is wrapped into a struct which is assigned a storage slot._

### constructor

```solidity
constructor() internal
```

### Accounts

```solidity
struct Accounts {
  mapping(address => struct ISmartPoolState.UserAccount) userAccounts;
}
```

### accounts

```solidity
function accounts() internal pure returns (struct MixinStorage.Accounts s)
```

### pool

```solidity
function pool() internal pure returns (struct Pool s)
```

### PoolWrapper

Pool initialization struct wrapper.

_Allows initializing pool as struct for better readability._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct PoolWrapper {
  struct Pool pool;
}
```

### poolWrapper

```solidity
function poolWrapper() internal pure returns (struct MixinStorage.PoolWrapper s)
```

### poolParams

```solidity
function poolParams() internal pure returns (struct ISmartPoolState.PoolParams s)
```

### poolTokens

```solidity
function poolTokens() internal pure returns (struct ISmartPoolState.PoolTokens s)
```

### activeTokensSet

```solidity
function activeTokensSet() internal pure returns (struct AddressSet s)
```

### activeApplications

```solidity
function activeApplications() internal pure returns (struct ApplicationsSlot s)
```

### Operator

```solidity
struct Operator {
  mapping(address => mapping(address => bool)) isApproved;
}
```

### operators

```solidity
function operators() internal pure returns (struct MixinStorage.Operator s)
```

### delegation

```solidity
function delegation() internal pure returns (struct DelegationData s)
```

### acceptedTokensSet

```solidity
function acceptedTokensSet() internal pure returns (struct AddressSet s)
```

