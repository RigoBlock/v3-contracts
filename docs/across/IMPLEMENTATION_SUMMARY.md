# Across Integration Implementation Summary

## Overview

Successfully implemented Across Protocol V3 integration for Rigoblock smart pools with complete NAV integrity management, security features, and comprehensive documentation.

## Changes Made

### 1. Core Contracts

#### AIntents.sol (Adapter)
- **Location**: `contracts/protocol/extensions/adapters/AIntents.sol`
- **Purpose**: Initiates cross-chain token transfers on source chain
- **Key Features**:
  - Matches Across `depositV3` interface exactly for seamless integration
  - Manages virtual balances on source chain to offset NAV changes
  - Supports two transfer modes: Transfer (NAV-neutral) and Rebalance (NAV-changing)
  - Handles native token wrapping automatically
  - Uses SafeTransferLib for token safety (USDT compatibility)
  - Calls updateUnitaryValue() before reading NAV for accuracy
  - Documents known limitation: token recovery not implemented due to Across V3 constraints

#### EAcrossHandler.sol (Extension)
- **Location**: `contracts/protocol/extensions/EAcrossHandler.sol`
- **Purpose**: Handles incoming cross-chain transfers on destination chain
- **Key Features**:
  - **Critical Security**: Verifies `msg.sender == acrossSpokePool` (immutable)
  - Validates tokens have price feeds before accepting
  - Manages virtual balances on destination chain
  - Handles native token unwrapping if requested
  - Normalizes NAV across different decimals for rebalance mode
  - Operates via delegatecall in pool context (stateless)

### 2. Infrastructure Updates

#### ExtensionsMap.sol
- **Location**: `contracts/protocol/deps/ExtensionsMap.sol`
- **Changes**:
  - Added `eAcrossHandler` immutable address
  - Added selector mapping for `handleV3AcrossMessage`
  - Set `shouldDelegatecall = true` for handler

#### ExtensionsMapDeployer.sol
- **Location**: `contracts/protocol/deps/ExtensionsMapDeployer.sol`
- **Changes**:
  - Added `eAcrossHandler` to transient storage
  - Updated `DeploymentParams` to include handler
  - Supports CREATE2 deployment with arbitrary salt for versioning

#### MixinStorage.sol
- **Location**: `contracts/protocol/core/immutable/MixinStorage.sol`
- **Changes**:
  - Added assertion for `_VIRTUAL_BALANCES_SLOT` in constructor
  - Ensures storage slot integrity: `keccak256("pool.proxy.virtualBalances") - 1`

#### MixinConstants.sol
- **Location**: `contracts/protocol/core/immutable/MixinConstants.sol`
- **Already Updated**: Virtual balances slot constant already defined

#### DeploymentParams.sol
- **Location**: `contracts/protocol/types/DeploymentParams.sol`
- **Already Updated**: Extensions struct includes eAcrossHandler

### 3. Interfaces

#### IAIntents.sol
- **Location**: `contracts/protocol/extensions/adapters/interfaces/IAIntents.sol`
- **Content**: Complete interface with NatSpec documentation for AIntents adapter

#### IEAcrossHandler.sol
- **Location**: `contracts/protocol/extensions/adapters/interfaces/IEAcrossHandler.sol`
- **Content**: Complete interface with NatSpec documentation for EAcrossHandler extension

#### IAcrossSpokePool.sol
- **Location**: `contracts/protocol/interfaces/IAcrossSpokePool.sol`
- **Content**: Across Protocol V3 SpokePool interface

### 4. Tests

#### AcrossUnit.t.sol
- **Location**: `test/extensions/AcrossUnit.t.sol`
- **Coverage**:
  - Adapter and handler deployment
  - Security checks (unauthorized caller rejection)
  - Message encoding/decoding
  - NAV normalization logic
  - Tolerance calculations
  - Interface compatibility
  - Storage slot verification
  - Fuzz tests for NAV normalization and tolerance

#### AcrossIntegrationFork.t.sol
- **Location**: `test/extensions/AcrossIntegrationFork.t.sol`
- **Coverage**:
  - Fork-based integration tests for Arbitrum, Optimism, Base
  - Infrastructure deployment on forks
  - Configuration verification
  - Security validation
  - Virtual balance storage operations
  - Cross-chain flow simulation
  - Interface compatibility checks

### 5. Documentation

#### CLAUDE.md
- **Location**: `/CLAUDE.md`
- **Content**: Comprehensive AI assistant guide covering:
  - Project architecture and patterns
  - Storage layout rules
  - NAV calculation system
  - Testing patterns
  - Common tasks and operations
  - Security considerations
  - Known pitfalls

#### AGENTS.md
- **Location**: `/AGENTS.md`
- **Content**: Quick reference guide with:
  - Critical rules
  - Architecture overview
  - Key files reference
  - Storage patterns
  - Common operations
  - Testing instructions
  - Deployed addresses

#### docs/across/
- **Location**: `/docs/across/`
- **Files Moved**:
  - `ACROSS_INTEGRATION_SUMMARY.md`
  - `ACROSS_INTEGRATION_IMPROVEMENTS.md`
  - `ACROSS_DEPLOYMENT_GUIDE.md`
  - `ACROSS_FINAL_SUMMARY.md`
  - `ACROSS_CRITICAL_FIXES.md`
  - `ACROSS_TESTS_README.md`
- **New File**: `README.md` - Consolidated overview of Across integration

## Key Design Decisions

### 1. Virtual Balances for NAV Integrity

**Problem**: Cross-chain transfers affect NAV on both chains (decrease on source, increase on destination).

**Solution**: Store virtual balances (signed integers) that offset real balance changes:
- Source chain: Positive virtual balance reduces NAV by locked amount
- Destination chain: Negative virtual balance increases NAV by received amount
- Stored in base token equivalent for gas efficiency

### 2. Two Transfer Modes

**Transfer Mode** (NAV-neutral):
- Use case: Moving liquidity without affecting vault value
- Source: Creates positive virtual balance
- Destination: Creates negative virtual balance

**Rebalance Mode** (NAV-changing):
- Use case: Transferring performance between chains
- Source: NAV changes naturally
- Destination: Verifies NAV matches source (within tolerance)
- Handles different base token decimals via normalization

### 3. Extension vs Adapter Pattern

**EAcrossHandler as Extension**:
- Mapped in ExtensionsMap (immutable per deployment)
- Called via delegatecall from pool
- Stateless (operates in pool context)
- Recipient is the pool itself (tokens already transferred by Across)

**AIntents as Adapter**:
- Mapped in Authority (upgradeable via governance)
- Called via delegatecall from pool
- Stateless (operates in pool context)

### 4. Security Model

**Critical Security Check**:
```solidity
require(msg.sender == acrossSpokePool, UnauthorizedCaller());
```

This is critical because:
- Handler called via delegatecall (runs in pool context)
- `msg.sender` preserved from original call
- Must verify caller is Across SpokePool to prevent unauthorized calls
- SpokePool address stored as immutable (gas efficient)

### 5. Token Recovery Limitation

**Decision**: Do NOT implement token recovery via `speedUpV3Deposit`

**Reasoning**:
- Across V3 lacks safe recovery mechanism
- `speedUpV3Deposit` can modify params even if deposit already filled
- Could cause NAV inflation if not handled correctly
- Risk > benefit for edge case

**Mitigation**:
- Use reasonable fillDeadline (5-30 minutes)
- Across fills deposits within seconds with proper params
- Document as known limitation

## Storage Layout

All new storage uses ERC-7201 namespaced pattern:

```solidity
// Storage slot for virtual balances
bytes32 constant _VIRTUAL_BALANCES_SLOT = 
    bytes32(uint256(keccak256("pool.proxy.virtualBalances")) - 1);
// Value: 0x19797d8be84f650fe18ebccb97578c2adb7abe9b7c86852694a3ceb69073d1d1

// Access pattern
mapping(address token => int256 virtualBalance)
```

**Storage Safety**:
- Slot asserted in MixinStorage.sol constructor
- No storage in extensions/adapters (run in pool context)
- Uses SlotDerivation library for nested mappings

## Test Results

### Unit Tests (Foundry)
```
Ran 15 tests for test/extensions/AcrossUnit.t.sol:AcrossUnitTest
[PASS] All 15 tests passed
- Deployment tests
- Security tests
- Message encoding tests
- NAV normalization tests
- Tolerance calculation tests
- Fuzz tests
```

### Integration Tests (Foundry)
Fork-based tests ready for execution with RPC URLs configured.

## Gas Optimization

1. **Immutable Variables**: acrossSpokePool, wrappedNative
2. **Transient Storage**: ReentrancyGuardTransient for reentrancy protection
3. **Base Token Virtual Balances**: Store in base token equivalent instead of per-token
4. **Cached Storage Reads**: Read pool state once into memory structs

## Deployment Requirements

### Per Chain Deployment

1. Deploy `EAcrossHandler` with chain-specific acrossSpokePool address
2. Deploy `AIntents` with chain-specific acrossSpokePool address
3. Deploy `ExtensionsMapDeployer` (if not exists)
4. Deploy `ExtensionsMap` via deployer with:
   - eAcrossHandler address
   - Existing extension addresses (eApps, eOracle, eUpgrade)
   - wrappedNative address
   - Arbitrary salt for versioning

### Governance Actions

1. Add AIntents methods to Authority (whitelister role)
2. Upgrade pool implementation to reference new ExtensionsMap (governance vote)

## Known Limitations

1. **Token Recovery**: Not implemented due to Across V3 constraints
2. **Rebalance Mode**: Requires source and destination chains to have similar NAV
3. **Price Feed Requirement**: Tokens must have price feed on destination chain
4. **Base Token Dependency**: Virtual balances in base token equivalent

## Future Improvements

1. Monitor Across Protocol for native recovery mechanisms
2. Consider partial rebalancing support
3. Protocol fee on transfers (surplus to token jar)
4. Support for non-EVM chains (when Across V4 ready)

## References

- Across Protocol: https://docs.across.to/
- Rigoblock Docs: https://docs.rigoblock.com/
- Implementation: `docs/across/`

## Verification

All changes have been:
- ✅ Compiled successfully with Solidity 0.8.28
- ✅ Unit tested (15/15 passing)
- ✅ Integration test framework ready
- ✅ Documented comprehensively
- ✅ Security reviewed
- ✅ Storage layout verified
- ✅ Interface compatibility confirmed
