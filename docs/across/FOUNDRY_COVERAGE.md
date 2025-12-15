# Across Contracts Foundry Test Coverage Summary

## Current Coverage

### EAcrossHandler.sol
- Line Coverage: 8.33% (5/60 lines)
- Function Coverage: 20.00% (2/10 functions)
- Branch Coverage: 15.79% (3/19 branches)

**Covered:**
- Constructor and basic validation
- Message encoding/decoding
- Selector calculations

**Not Covered (requires delegatecall context):**
- `handleV3AcrossMessage()` full execution
- `_handleTransferMode()` 
- `_handleRebalanceMode()`
- `_handleSyncMode()`
- `_normalizeNav()`
- Virtual balance storage operations

### AIntents.sol  
- Line Coverage: 29.27% (12/41 lines)
- Function Coverage: 44.44% (4/9 functions)
- Branch Coverage: 47.06% (8/17 branches)

**Covered:**
- Constructor and immutables
- Direct call rejection
- Input validation (null checks, inactive tokens)
- Required version
- Message structure

**Not Covered (requires delegatecall context):**
- `depositV3()` full execution with SpokePool interaction
- `_processMessage()` with storage access
- `_adjustVirtualBalanceForTransfer()` 
- `_safeApproveToken()` with real tokens

## Why Coverage Is Limited

Both contracts are **adapters/extensions that run via delegatecall from a pool proxy**. This means:

1. Most functions require pool storage context (StorageLib, active tokens, baseToken, etc.)
2. Functions need proper ERC20 tokens with balances
3. Integration with Across SpokePool requires fork testing
4. Virtual balance operations require actual pool state

## Test Coverage Strategy

### Unit Tests (AcrossUnit.t.sol)
- Test message encoding/decoding ✓
- Test input validation ✓
- Test enum values and constants ✓
- Test unauthorized caller rejection ✓
- Test NAV normalization math ✓
- Test tolerance calculations ✓
- Mock-based tests for structure ✓

### Fork Tests (AcrossIntegrationFork.t.sol)
- Test with real deployed contracts ✓
- Test configuration and deployment ✓
- Test cross-chain message flow ✓
- Test virtual balance storage ✓  
- Test OpType variations ✓

### Hardhat Tests (Across.spec.ts)
- Full end-to-end execution with deployed pool
- Real token transfers and approvals
- Actual Across SpokePool interaction
- Complete delegatecall context
- **This is where most execution coverage happens**

## Recommendations

1. **Foundry tests are appropriate** - Unit tests cover structure, fork tests verify deployment
2. **Hardhat tests provide execution coverage** - This is by design, as they test the full system
3. **Combined coverage needed** - Use `yarn coverage:combined` to see total coverage across both frameworks
4. **Don't chase 100% in Foundry alone** - The architecture requires multi-framework testing

## Coverage Improvement Options

To improve Foundry-only coverage would require:
1. Creating a mock pool contract with full storage simulation
2. Implementing all pool interfaces (StorageLib, IEOracle, etc.)
3. Mocking ERC20 tokens with balances and approvals
4. Simulating delegatecall context properly
5. **This is complex and provides diminishing returns vs using Hardhat tests**

Current approach (Foundry for unit/structure + Hardhat for execution) is optimal.
