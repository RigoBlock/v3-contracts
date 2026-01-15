# Across Bridge Integration for Rigoblock Smart Pools

## Overview

Cross-chain token transfer integration using [Across Protocol V3](https://across.to/), maintaining NAV (Net Asset Value) integrity through virtual balance system.

## Architecture

### Components

**AIntents.sol** (Source Chain Adapter)
- Path: `contracts/protocol/extensions/adapters/AIntents.sol`
- Initiates transfers via `depositV3()`
- Manages source chain virtual adjustments in base token units
- Encodes destination instructions as multicall

**ECrosschain.sol** (Destination Chain Extension)
- Path: `contracts/protocol/extensions/ECrosschain.sol`
- Receives via `handleV3AcrossMessage()` (called by SpokePool)
- Validates NAV changes and applies virtual supply adjustments
- Handles Transfer (NAV-neutral) and Sync (NAV change) modes

**Virtual System**
- **Virtual Supply**: Pool token shares representing cross-chain holdings (in pool token units)
- **Virtual Balances**: Base token adjustments for transferred tokens (in base token units)
- Maintains NAV integrity and correct performance attribution during cross-chain operations

### Transfer Modes

**Transfer Mode (OpType.Transfer)** - Default, NAV-neutral
- **Source chain**: Writes positive base token virtual balance (fixed value at transfer time)
  - Source NAV remains constant regardless of token price changes
  - Virtual balance in base token units does not fluctuate with token price
- **Destination chain**: Writes virtual supply (reduces effective token supply)
  - Destination NAV changes with token price movements
  - Destination gets all price performance attribution
- **Bridge fees**: Reduce NAV (real economic cost, split between chains)
- **Use for**: Moving liquidity between chains

**Sync Mode (OpType.Sync)** - Allows NAV changes
- No virtual adjustments applied
- NAV validated within tolerance range
- Solver surplus benefits pool holders
- Use for: Donations, rebalancing, performance transfers

### Performance Attribution

**Price Appreciation** (e.g., USDC $1.00 → $1.10):
- Source NAV: Constant (base token VB fixed at transfer price)
- Destination NAV: Increases (real tokens appreciate)
- **Winner**: Destination chain holders

**Price Depreciation** (e.g., USDC $1.00 → $0.90):
- Source NAV: Constant (base token VB fixed at transfer price)
- Destination NAV: Decreases (real tokens depreciate)
- **Winner**: Source chain holders (avoided loss)

**Trading Gains/Losses** (constant token price):
- Split pro-rata between local and virtual supply holders
- Fair attribution via virtual supply mechanism

## Documentation

- **[PERFORMANCE_ATTRIBUTION.md](PERFORMANCE_ATTRIBUTION.md)** - Detailed explanation of performance attribution model
- **[COMPREHENSIVE_ANALYSIS.md](COMPREHENSIVE_ANALYSIS.md)** - Deep technical analysis of virtual systems
- **[IMPLEMENTATION_GUIDE.md](IMPLEMENTATION_GUIDE.md)** - Implementation details, testing, deployment

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
2. **Virtual balance atomicity**: Must read/update in same transaction
3. **Bridge fees**: Always reduce NAV (real economic cost)
4. **Solver surplus**: Small NAV increase in Sync mode (benefits holders)
5. **Rebalancing edge case**: When all tokens transferred and prices depreciate, requires 2-step rebalancing (destination→source, then source→destination)

## Key Design Decision: Base Token Virtual Balances

The implementation uses **base token denominated virtual balances** on the source chain rather than token-denominated balances. This design choice:

**Benefits:**
- ✅ Simpler implementation (single VB write, single VS write)
- ✅ Lower gas costs (~5,800 gas savings per transfer)
- ✅ Performance follows physical custody (destination gets price movements)
- ✅ Direct rebalancing possible when tokens appreciate (most common case)

**Trade-off:**
- ⚠️ Destination chain gets price performance (not source)
- ⚠️ Requires 2-step rebalancing when tokens depreciate AND all tokens transferred (rare)

This approach prioritizes practical operability over conceptual "ownership" attribution, as the chain holding the tokens is better positioned to rebalance.

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
- Source: 1 SSTORE (base token VB)
- Destination: 1-2 SSTORE (VS, optionally clear base token VB)
- Total: ~8,900 gas for virtual accounting

**vs Previous Approach** (Option 4 - not implemented):
- Would require 3 SSTORE operations on destination
- Additional ~5,800 gas per transfer
- More complex logic (special case handling)

### Testing Strategy

**Unit Tests** (`test/extensions/AIntentsRealFork.t.sol`):
- Fork-based tests using real deployed contracts
- Tests both USDC (6 decimals) and WETH (18 decimals)
- Verifies base token unit storage
- Tests virtual supply management
- Cross-chain integration scenarios

**Key Test Cases**:
- `test_IntegrationFork_CrossChain_TransferWithHandler` - End-to-end transfer
- `test_IntegrationFork_Transfer_NonBaseToken` - Non-base token (WETH) transfers
- `test_AIntents_VirtualSupply_WithNonBaseToken` - Virtual supply burn logic
- `test_IntegrationFork_ECrosschain_PartialVirtualBalanceReduction` - Inbound with existing VB

All 44 tests passing ✅

- [Across Protocol Docs](https://docs.across.to/)
- [Rigoblock Docs](https://docs.rigoblock.com)
- [Deployed Contracts](https://docs.rigoblock.com/readme-2/deployed-contracts-v4)
