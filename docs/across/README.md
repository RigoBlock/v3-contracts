# Across Protocol Integration for Rigoblock Smart Pools

This directory contains documentation for the Across Protocol V3 integration with Rigoblock smart pools, enabling secure cross-chain token transfers while maintaining NAV (Net Asset Value) integrity.

## Overview

The integration consists of two main components:

1. **AIntents.sol** (Adapter) - Initiates cross-chain transfers on the source chain
2. **EAcrossHandler.sol** (Extension) - Handles incoming transfers on the destination chain

## Key Features

- **NAV Integrity**: Virtual balances ensure NAV remains accurate across chains
- **Two Transfer Modes**:
  - **Transfer Mode**: NAV-neutral transfers with virtual balance offsets
  - **Rebalance Mode**: Performance transfers with NAV verification
- **Security**: Handler verifies caller is Across SpokePool
- **Token Safety**: Validates price feeds before accepting tokens

## Documentation Files

- **ACROSS_INTEGRATION_SUMMARY.md** - High-level integration overview
- **ACROSS_INTEGRATION_IMPROVEMENTS.md** - Design improvements and decisions
- **ACROSS_DEPLOYMENT_GUIDE.md** - Deployment instructions
- **ACROSS_FINAL_SUMMARY.md** - Final implementation summary
- **ACROSS_CRITICAL_FIXES.md** - Critical fixes and security considerations
- **ACROSS_TESTS_README.md** - Testing guide and patterns

## Quick Start

### For Developers

1. Read **ACROSS_INTEGRATION_SUMMARY.md** for overview
2. Review contract code:
   - `contracts/protocol/extensions/adapters/AIntents.sol`
   - `contracts/protocol/extensions/EAcrossHandler.sol`
3. Check interfaces:
   - `contracts/protocol/extensions/adapters/interfaces/IAIntents.sol`
   - `contracts/protocol/extensions/adapters/interfaces/IEAcrossHandler.sol`
4. Run tests: `forge test --match-path test/extensions/AcrossIntegrationFork.t.sol`

### For Integrators

1. Read **ACROSS_DEPLOYMENT_GUIDE.md** for deployment steps
2. Review **ACROSS_CRITICAL_FIXES.md** for security considerations
3. Understand the two transfer modes and when to use each

## Transfer Modes Explained

### Transfer Mode (NAV Neutral)

Use when transferring tokens without wanting to affect NAV on either chain.

**How it works:**
- Source chain: Creates positive virtual balance (reduces NAV by locked amount)
- Destination chain: Creates negative virtual balance (increases NAV by received amount)
- Net effect: NAV unchanged on both chains

**Use case:** Moving liquidity between chains while maintaining vault value

### Rebalance Mode (NAV Changes)

Use when intentionally transferring performance between chains.

**How it works:**
- Source chain: NAV changes naturally (tokens sent)
- Destination chain: Verifies NAV matches source (within tolerance)
- Accounts for different base token decimals

**Use case:** Rebalancing vault performance across chains

## Architecture

```
Source Chain:
User → Pool → AIntents Adapter → Across SpokePool
                ↓
         Update Virtual Balance
         
Destination Chain:
Across SpokePool → Pool → EAcrossHandler Extension
                            ↓
                     Verify & Update Virtual Balance
```

## Security Model

1. **Handler Verification**: Extension MUST verify `msg.sender == acrossSpokePool`
2. **Price Feed Validation**: Only tokens with price feeds are accepted
3. **NAV Tolerance**: Rebalance mode enforces NAV deviation limits
4. **No Direct Calls**: Extensions/adapters only callable via pool delegatecall

## Known Limitations

**Token Recovery**: Across V3 does not provide a direct mechanism to reclaim tokens from unfilled deposits. The `speedUpV3Deposit` method can update parameters but may not safely recover tokens if the deposit was already filled.

**Mitigation**: Use reasonable fillDeadline values (5-30 minutes). Across typically fills deposits within seconds to minutes with proper parameters.

## Storage

Virtual balances are stored using ERC-7201 namespaced storage:

```solidity
// Storage slot
bytes32 constant VIRTUAL_BALANCES_SLOT = 
    bytes32(uint256(keccak256("pool.proxy.virtualBalances")) - 1);

// Access pattern
mapping(address token => int256 virtualBalance)
```

## Testing

Tests are located in `test/extensions/`:
- `AcrossUnit.t.sol` - Unit tests for individual components
- `AcrossIntegrationFork.t.sol` - Fork-based integration tests

See **ACROSS_TESTS_README.md** for detailed testing guide.

## Deployed Addresses

### Across SpokePool Contracts

- **Ethereum Mainnet**: `0x5c7BCd6E7De5423a257D81B442095A1a6ced35C5`
- **Arbitrum**: `0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A`
- **Optimism**: `0x6f26Bf09B1C792e3228e5467807a900A503c0281`
- **Base**: `0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64`
- **Polygon**: `0x9295ee1d8C5b022Be115A2AD3c30C72E34e7F096`

### Rigoblock Contracts

See https://docs.rigoblock.com/readme-2/deployed-contracts-v4 for full list.

## References

- [Across Protocol Docs](https://docs.across.to/)
- [Rigoblock Docs](https://docs.rigoblock.com/)
- [GitHub Repository](https://github.com/RigoBlock/v3-contracts)

## Support

For questions or issues:
- GitHub Issues: https://github.com/RigoBlock/v3-contracts/issues
- Discord: https://discord.gg/rigoblock
