# Cross-Chain Considerations

This document summarizes the practical cross-chain rules used by Rigoblock. For the formal Virtual Supply model, see [CROSSCHAIN_NAV_SYNC_PAPER.md](./CROSSCHAIN_NAV_SYNC_PAPER.md). For the Across-specific integration, see [across/README.md](./across/README.md).

## Same address across chains

The following contracts are designed to have the same address on every chain:

- Authority, Registry, Factory
- Pool proxies (if deployed with the same params)
- Core implementations
- Staking suite, Governance core
- **ExtensionsMap** — deployed via `ExtensionsMapDeployer` with a chain-independent salt.

`ExtensionsMap` has **no constructor parameters**. The deployment params (extension addresses, wrapped native) are written to the `ExtensionsMapDeployer`'s storage and read by the `ExtensionsMap` constructor at deploy time (`msg.sender` context). The map is always deployed via `ExtensionsMapDeployer.deployExtensionsMap(params, salt)`, and its CREATE2 address depends only on the deployer contract's address, the salt, and `type(ExtensionsMap).creationCode`. Same code + same salt ⇒ same address on every chain. Apparent mismatches on production chains are upgrade-timing artifacts, not by-design per-chain addresses.

## Different address per chain

The following are chain-specific:

- Individual extensions (`EApps`, `EOracle`, `EUpgrade`, `ECrosschain`) — chain-specific constructor params.
- Governance strategy.

## NAV integrity in cross-chain transfers

Bridging affects NAV on both chains. The Virtual Supply system keeps NAV consistent.

### Transfer Mode (NAV neutral)

- **Source**: writes **negative Virtual Supply** (`shares = outputValue / NAV`).
- **Destination**: writes **positive Virtual Supply** (`shares = receivedValue / NAV`).
- NAV remains unchanged on both chains; effective supply adjusts proportionally.

### Sync Mode (NAV changes)

- No virtual supply adjustments.
- NAV changes naturally as tokens leave the source and arrive at the destination.
- Use for donations or rebalancing.

### Implementation

```solidity
// Virtual supply storage (single slot per pool)
bytes32 slot = VIRTUAL_SUPPLY_SLOT;

// Get current virtual supply
int256 vs;
assembly { vs := sload(slot) }

// Update virtual supply
int256 newVs = vs + delta;
assembly { sstore(slot, newVs) }
```

Cross-chain transfers **must** manage virtual supply to maintain NAV integrity.
