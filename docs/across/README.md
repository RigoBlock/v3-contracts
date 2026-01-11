# Across Bridge Integration for Rigoblock Smart Pools

## Overview

Cross-chain token transfer integration using [Across Protocol V3](https://across.to/), maintaining NAV (Net Asset Value) integrity through virtual balance system.

## Architecture

### Components

**AIntents.sol** (Source Chain Adapter)
- Path: `contracts/protocol/extensions/adapters/AIntents.sol`
- Initiates transfers via `depositV3()`
- Manages source chain virtual adjustments
- Encodes destination instructions as multicall

**EAcrossHandler.sol** (Destination Chain Extension)
- Path: `contracts/protocol/extensions/EAcrossHandler.sol`
- Receives via `handleV3AcrossMessage()` (called by SpokePool)
- Validates NAV changes and applies adjustments
- Handles Transfer (NAV-neutral) and Sync (NAV change) modes

**Virtual System**
- **Virtual Supply**: Pool token shares across chains (in pool token units)
- **Virtual Balances**: Per-token NAV adjustments (in base token units)
- Maintains NAV integrity during cross-chain operations

### Transfer Modes

**Transfer Mode (OpType.Transfer)** - Default, NAV-neutral
- Source creates positive virtual balance to offset token loss
- Destination creates negative virtual balance to offset token gain
- Bridge fees reduce NAV (real economic cost)
- Use for: Moving liquidity between chains

**Sync Mode (OpType.Sync)** - Allows NAV changes
- No virtual adjustments applied
- NAV validated within tolerance range
- Solver surplus benefits pool holders
- Use for: Donations, rebalancing, performance transfers

## Documentation

- **COMPREHENSIVE_ANALYSIS.md** - Deep technical analysis of virtual systems
- **IMPLEMENTATION_GUIDE.md** - Implementation details, testing, deployment

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

// Destination chain (EAcrossHandler)
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

## Resources

- [Across Protocol Docs](https://docs.across.to/)
- [Rigoblock Docs](https://docs.rigoblock.com)
- [Deployed Contracts](https://docs.rigoblock.com/readme-2/deployed-contracts-v4)
