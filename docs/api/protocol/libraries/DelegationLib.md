# Solidity API

## DelegationData

Per-pool delegated-access state stored at a dedicated ERC-7201 slot.

_Four parallel data structures maintain two enumerable mappings:
     selector → [delegated addresses]  (for revoke-by-selector)
     address  → [delegated selectors]  (for revoke-by-address)
     Both directions are kept in O(1) via position tracking (1-indexed, 0 = absent)._

```solidity
struct DelegationData {
  mapping(bytes4 => mapping(address => uint256)) selectorToAddressPosition;
  mapping(bytes4 => address[]) selectorAddresses;
  mapping(address => bytes4[]) addressSelectors;
  mapping(address => mapping(bytes4 => uint256)) addressToSelectorPosition;
}
```

## DelegationLib

Library for managing granular per-selector delegated write access to pool adapters.

_All writes maintain two enumerable index structures so callers can enumerate delegations
     in either direction without iterating unpredictably large arrays._

### add

```solidity
function add(struct DelegationData self, bytes4 selector, address addr) internal returns (bool added)
```

Grants delegated write access to `selector` for `addr`.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| added | bool | True if the pair was newly granted (false = already existed, no storage change). |

### remove

```solidity
function remove(struct DelegationData self, bytes4 selector, address addr) internal returns (bool removed)
```

Revokes delegated write access to `selector` for `addr`.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| removed | bool | True if the pair was present and removed (false = was not delegated, no storage change). |

### removeAllByAddress

```solidity
function removeAllByAddress(struct DelegationData self, address addr) internal
```

Revokes all delegations previously granted to `addr` (e.g. compromised wallet).

_Iterates the (short) list of selectors for addr and cleans up both directions._

### removeAllBySelector

```solidity
function removeAllBySelector(struct DelegationData self, bytes4 selector) internal
```

Revokes all delegations for `selector` (e.g. adapter being replaced by governance).

_Iterates the (short) list of addresses for selector and cleans up both directions._

### getAddresses

```solidity
function getAddresses(struct DelegationData self, bytes4 selector) internal view returns (address[])
```

Returns all addresses currently delegated for `selector`.

### getSelectors

```solidity
function getSelectors(struct DelegationData self, address addr) internal view returns (bytes4[])
```

Returns all selectors currently delegated to `addr`.

