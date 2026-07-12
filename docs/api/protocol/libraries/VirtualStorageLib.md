# Solidity API

## VirtualStorageLib

Provides functions to get and update virtual supply (VS-only model)

_Uses ERC-7201 namespaced storage pattern
VS-only model: Transfer writes negative VS on source (NAV-neutral), positive VS on destination
     Sync has no VS impact (NAV-impacting on both chains)_

### VIRTUAL_SUPPLY_SLOT

```solidity
bytes32 VIRTUAL_SUPPLY_SLOT
```

### VirtualSupply

```solidity
struct VirtualSupply {
  int256 supply;
}
```

### virtualSupply

```solidity
function virtualSupply() internal pure returns (struct VirtualStorageLib.VirtualSupply s)
```

### updateVirtualSupply

```solidity
function updateVirtualSupply(int256 delta) internal
```

### getVirtualSupply

```solidity
function getVirtualSupply() internal view returns (int256)
```

