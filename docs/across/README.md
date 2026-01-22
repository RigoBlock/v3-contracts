# Across Bridge Integration for Rigoblock Smart Pools

## Overview

Cross-chain token transfer integration using [Across Protocol V3](https://across.to/), maintaining NAV (Net Asset Value) integrity through Virtual Supply (VS) system.

## Architecture

### Components

**AIntents.sol** (Source Chain Adapter)
- Path: `contracts/protocol/extensions/adapters/AIntents.sol`
- Initiates transfers via `depositV3()`
- Writes **negative VS** on source (shares leaving this chain)
- Encodes destination instructions as multicall

**ECrosschain.sol** (Destination Chain Extension)
- Path: `contracts/protocol/extensions/ECrosschain.sol`
- Receives via `handleV3AcrossMessage()` (called by SpokePool)
- Writes **positive VS** on destination (shares arriving)
- Validates NAV changes and applies virtual supply adjustments
- Handles Transfer (NAV-neutral) and Sync (NAV change) modes

**Virtual Supply (VS-Only Model)**
- **Virtual Supply**: Pool token shares representing cross-chain holdings
- **Source chain**: Negative VS (shares sent away → reduces effective supply)
- **Destination chain**: Positive VS (shares received → increases effective supply)
- Maintains NAV integrity during cross-chain operations

### Transfer Modes

**Transfer Mode (OpType.Transfer)** - Default, NAV-neutral
- **Source chain**: Writes **negative VS** (shares = outputValue / NAV)
  - Source NAV remains constant (tokens leave, but supply effectively decreases)
  - Effective supply = totalSupply + virtualSupply (where VS is negative)
- **Destination chain**: Writes **positive VS** (shares = receivedValue / NAV)
  - Destination NAV remains constant (tokens arrive, supply effectively increases)
  - VS may clear existing negative VS if chain had prior outbound transfers
- **Bridge fees**: Reduce NAV (real economic cost)
- **Use for**: Moving liquidity between chains

**Sync Mode (OpType.Sync)** - Allows NAV changes
- No virtual adjustments applied
- NAV validated within tolerance range
- Solver surplus benefits pool holders
- Use for: Donations, rebalancing, performance transfers

### Performance Attribution

With VS-only model, both chains share performance proportionally:
- Trading gains/losses split by effective supply ratios
- Local holders: (supply / effectiveSupply) × gains
- Virtual holders: (|VS| / effectiveSupply) × gains

**Price Changes**: Affect both chains proportionally through the effective supply mechanism

**Trading Gains/Losses** (constant token price):
- Split pro-rata between local and virtual supply holders
- Fair attribution via virtual supply mechanism

## Documentation

- **[PERFORMANCE_ATTRIBUTION.md](PERFORMANCE_ATTRIBUTION.md)** - Detailed explanation of performance attribution model
- **[COMPREHENSIVE_ANALYSIS.md](COMPREHENSIVE_ANALYSIS.md)** - Deep technical analysis of virtual systems
- **[IMPLEMENTATION_GUIDE.md](IMPLEMENTATION_GUIDE.md)** - Implementation details, testing, deployment
- **[ZERO_SUPPLY_DOS_VULNERABILITY.md](ZERO_SUPPLY_DOS_VULNERABILITY.md)** - Fixed DOS vulnerability analysis (resolved Jan 2026)

## Quick Reference

### Key Methods

```solidity
// Source chain (AIntents)
function depositV3(
    address inputToken,
    uint256 inputAmount,
    uint256 outputAmount,
    uint256 destinationChainId,
    address exclusiveRelayer,
    uint32 fillDeadline,
    bytes calldata message
) external;

// Destination chain (ECrosschain)
function handleV3AcrossMessage(
    address tokenSent,
    uint256 amount,
    address relayer,
    bytes memory message
) external;
```

### Security Model

1. **Handler verification**: Only Across SpokePool can call handler
2. **Price feed validation**: Token must have price feed before acceptance
3. **NAV validation**: Final NAV checked against expected value
4. **Virtual balance consistency**: Read and update within same transaction

### Testing

```bash
# Run all Across tests
forge test --match-path test/extensions/AIntentsRealFork.t.sol -vv

# Test specific scenario
forge test --match-test test_AIntents_SufficientVirtualSupply -vvv
```

### Deployed Addresses

Core contracts (most chains):
- Authority: `0x7F427F11eB24f1be14D0c794f6d5a9830F18FBf1`
- Factory: `0x4aA9e5A5A244C81C3897558C5cF5b752EBefA88f`
- Registry: `0x19Be0f8D5f35DB8c2d2f50c9a3742C5d1eB88907`

Across SpokePool addresses vary by chain - see Constants.sol

## Known Limitations

1. **No recovery mechanism**: Across V3 lacks direct token recovery
2. **Effective supply constraint**: Negative VS limited to 90% of total supply
3. **Bridge fees**: Always reduce NAV (real economic cost)
4. **Solver surplus**: Small NAV increase in Sync mode (benefits holders)

## Key Design Decision: Virtual Supply Only Model

The implementation uses **Virtual Supply (VS) only** rather than the previous VB+VS dual system. This design choice:

**How it works:**
- **Source chain**: Writes negative VS (shares leaving → effective supply decreases)
- **Destination chain**: Writes positive VS (shares arriving → effective supply increases)
- NAV = totalValue / effectiveSupply, where effectiveSupply = totalSupply + virtualSupply

**Benefits:**
- ✅ Simpler implementation (single VS adjustment per chain)
- ✅ Lower gas costs (one storage write per side)
- ✅ No VB/VS synchronization complexity
- ✅ Performance shared proportionally between chains
- ✅ 10% safety buffer prevents supply exhaustion

**Trade-off:**
- ⚠️ Source cannot send more than 90% of effective supply in a single transfer
- ⚠️ Post-burn check required to prevent bypassing effective supply limit

## Resources

- [Across Protocol Docs](https://docs.across.to/)
- [Rigoblock Docs](https://docs.rigoblock.com)
- [Deployed Contracts](https://docs.rigoblock.com/readme-2/deployed-contracts-v4)

## Implementation Notes

### Gas Optimizations

**Conversion Efficiency** (ECrosschain):
- Single token→base conversion at entry
- All calculations in base token units
- No redundant base→token→base conversions
- Saves ~3,000 gas per transfer

**Storage Efficiency**:
- Source: 1 SSTORE (negative VS)
- Destination: 1 SSTORE (positive VS, clears existing negative VS if any)
- Total: ~5,000 gas for virtual accounting

### Testing Strategy

**Integration Tests** (`test/extensions/AIntentsRealFork.t.sol`):
- Fork-based tests using real deployed contracts
- Tests both USDC (6 decimals) and WETH (18 decimals)
- Verifies VS-only model behavior
- Tests virtual supply management
- Cross-chain integration scenarios

**Key Test Cases**:
- `test_IntegrationFork_CrossChain_TransferWithHandler` - End-to-end transfer
- `test_IntegrationFork_Transfer_NonBaseToken` - Non-base token (WETH) transfers
- `test_AIntents_VirtualSupply_WithNonBaseToken` - Virtual supply management
- Effective supply constraint tests

## Resources

- [Across Protocol Docs](https://docs.across.to/)
- [Rigoblock Docs](https://docs.rigoblock.com)
- [Deployed Contracts](https://docs.rigoblock.com/readme-2/deployed-contracts-v4)
