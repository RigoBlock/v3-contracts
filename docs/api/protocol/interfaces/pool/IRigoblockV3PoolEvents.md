# Solidity API

## IRigoblockV3PoolEvents

### PoolInitialized

```solidity
event PoolInitialized(address group, address owner, address baseToken, string name, bytes8 symbol)
```

Emitted when a new pool is initialized.

_Pool is initialized at new pool creation._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| group | address | Address of the factory. |
| owner | address | Address of the owner. |
| baseToken | address | Address of the base token. |
| name | string | String name of the pool. |
| symbol | bytes8 | String symbol of the pool. |

### NewOwner

```solidity
event NewOwner(address old, address current)
```

Emitted when new owner is set.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| old | address | Address of the previous owner. |
| current | address | Address of the new owner. |

### NewNav

```solidity
event NewNav(address poolOperator, address pool, uint256 unitaryValue)
```

Emitted when pool operator updates NAV.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| poolOperator | address | Address of the pool owner. |
| pool | address | Address of the pool. |
| unitaryValue | uint256 | Value of 1 token in wei units. |

### NewFee

```solidity
event NewFee(address pool, address who, uint16 transactionFee)
```

Emitted when pool operator sets new mint fee.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| pool | address | Address of the pool. |
| who | address | Address that is sending the transaction. |
| transactionFee | uint16 | Number of the new fee in wei. |

### NewCollector

```solidity
event NewCollector(address pool, address who, address feeCollector)
```

Emitted when pool operator updates fee collector address.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| pool | address | Address of the pool. |
| who | address | Address that is sending the transaction. |
| feeCollector | address | Address of the new fee collector. |

### MinimumPeriodChanged

```solidity
event MinimumPeriodChanged(address pool, uint48 minimumPeriod)
```

Emitted when pool operator updates minimum holding period.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| pool | address | Address of the pool. |
| minimumPeriod | uint48 | Number of seconds. |

### SpreadChanged

```solidity
event SpreadChanged(address pool, uint16 spread)
```

Emitted when pool operator updates the mint/burn spread.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| pool | address | Address of the pool. |
| spread | uint16 | Number of the spread in basis points. |

### KycProviderSet

```solidity
event KycProviderSet(address pool, address kycProvider)
```

Emitted when pool operator sets a kyc provider.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| pool | address | Address of the pool. |
| kycProvider | address | Address of the kyc provider. |

