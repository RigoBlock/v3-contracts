# Solidity API

## StorageLib

A library for extensions to access proxy pre-assigned storage slots.

### APPLICATIONS_SLOT

```solidity
bytes32 APPLICATIONS_SLOT
```

persistent storage slots, used to read from proxy storage without having to update implementation

### DELEGATION_SLOT

```solidity
bytes32 DELEGATION_SLOT
```

### POOL_INIT_SLOT

```solidity
bytes32 POOL_INIT_SLOT
```

### POOL_TOKENS_SLOT

```solidity
bytes32 POOL_TOKENS_SLOT
```

### TOKEN_REGISTRY_SLOT

```solidity
bytes32 TOKEN_REGISTRY_SLOT
```

### UNIV4_TOKEN_IDS_SLOT

```solidity
bytes32 UNIV4_TOKEN_IDS_SLOT
```

### pool

```solidity
function pool() internal pure returns (struct Pool s)
```

### delegation

```solidity
function delegation() internal pure returns (struct DelegationData s)
```

### activeTokensSet

```solidity
function activeTokensSet() internal pure returns (struct AddressSet s)
```

### uniV4TokenIdsSlot

```solidity
function uniV4TokenIdsSlot() internal pure returns (struct TokenIdsSlot s)
```

### activeApplications

```solidity
function activeApplications() internal pure returns (struct ApplicationsSlot s)
```

### isOwnedToken

```solidity
function isOwnedToken(address token) internal view returns (bool)
```

Checks if a token is owned by the pool (base token or active token)

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| token | address | Token address to check |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | True if token is base token or in active tokens set |

