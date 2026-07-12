# Solidity API

## MixinOwnerActions

### PoolCallerIsNotOwner

```solidity
error PoolCallerIsNotOwner()
```

### PoolFeeBiggerThanMax

```solidity
error PoolFeeBiggerThanMax(uint16 maxFee)
```

### PoolInputIsNotContract

```solidity
error PoolInputIsNotContract()
```

### OwnerActionInputIsSameAsCurrent

```solidity
error OwnerActionInputIsSameAsCurrent()
```

### PoolLockupPeriodInvalid

```solidity
error PoolLockupPeriodInvalid(uint48 minimum, uint48 maximum)
```

### PoolNullOwnerInput

```solidity
error PoolNullOwnerInput()
```

### PoolSpreadInvalid

```solidity
error PoolSpreadInvalid(uint16 maxSpread)
```

### onlyOwner

```solidity
modifier onlyOwner()
```

### changeFeeCollector

```solidity
function changeFeeCollector(address feeCollector) external
```

Allows owner to decide where to receive the fee.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| feeCollector | address | Address of the fee receiver. |

### changeMinPeriod

```solidity
function changeMinPeriod(uint48 minPeriod) external
```

Allows pool owner to change the minimum holding period.

_Minimum period is always at least 10 to prevent flash txs._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| minPeriod | uint48 | Time in seconds. |

### changeSpread

```solidity
function changeSpread(uint16 newSpread) external
```

Allows pool owner to change the mint/burn spread.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| newSpread | uint16 | Number between 0 and 1000, in basis points. |

### purgeInactiveTokensAndApps

```solidity
function purgeInactiveTokensAndApps() external
```

Allows the owner to remove all inactive token and applications.

_This is the only endpoint that has access to removing a token from the active tokens tuple.
Used to reduce cost of mint/burn as more tokens are traded, and allow lower gas for hft._

### revokeAllDelegations

```solidity
function revokeAllDelegations(address delegated) external
```

Revokes all selector delegations for a given address in a single call.

_Useful when a delegated wallet is compromised._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| delegated | address | Address whose full delegation is to be revoked. |

### revokeAllDelegationsForSelector

```solidity
function revokeAllDelegationsForSelector(bytes4 selector) external
```

Revokes all address delegations for a given selector in a single call.

_Useful when an adapter is being replaced by governance and stale delegates should be cleaned._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| selector | bytes4 | Selector whose full delegation list is to be cleared. |

### setAcceptableMintToken

```solidity
function setAcceptableMintToken(address token, bool isAccepted) external
```

Allows the owner to set acceptable mint tokens other than the base token.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| token | address | Address of the target token. |
| isAccepted | bool | Boolean to indicate whether the token is to be added or removed from storage. |

### setKycProvider

```solidity
function setKycProvider(address kycProvider) external
```

Allows pool owner to set/update the user whitelist contract.

_Kyc provider can be set to null, removing user whitelist requirement._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| kycProvider | address | Address if the kyc provider. |

### setOwner

```solidity
function setOwner(address newOwner) external
```

Allows pool owner to set a new owner address.

_Method restricted to owner._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| newOwner | address | Address of the new owner. |

### setTransactionFee

```solidity
function setTransactionFee(uint16 transactionFee) external
```

Allows pool owner to set the transaction fee.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| transactionFee | uint16 | Value of the transaction fee in basis points. |

### updateDelegation

```solidity
function updateDelegation(struct Delegation[] delegations) external
```

Allows pool owner to batch grant or revoke delegated adapter write access.

_Each entry independently adds or removes one (selector, address) pair.
     Emits DelegationUpdated only for entries that change storage (idempotent operations emit no event)._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| delegations | struct Delegation[] | Array of delegation operations to apply. |

