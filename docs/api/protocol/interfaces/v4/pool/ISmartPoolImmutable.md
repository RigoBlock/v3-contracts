# Solidity API

## ISmartPoolImmutable

### VERSION

```solidity
function VERSION() external view returns (string)
```

Returns a string of the pool version.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | string | String of the pool implementation version. |

### authority

```solidity
function authority() external view returns (address)
```

Returns the address of the authority contract.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Address of the authority contract. |

### wrappedNative

```solidity
function wrappedNative() external view returns (address)
```

Returns the address of the WETH9 contract.

_Used to convert WETH balances to ETH without executing an oracle call._

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Address of the WETH9 contract. |

### tokenJar

```solidity
function tokenJar() external view returns (address)
```

Returns the address of the Rigoblock token jar contract.

_Used to transfer protocol fees to the buy-back-and-burn contract._

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Address of the token jar contract. |

