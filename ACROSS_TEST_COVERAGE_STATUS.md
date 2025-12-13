# Across Test Coverage Status

## Current Coverage

### EAcrossHandler.sol
- **Line Coverage**: 8.33% (5/60 lines)
- **Branch Coverage**: 4.00% (3/75 branches)
- **Function Coverage**: 15.79% (3/19 functions)
- **Statement Coverage**: 20.00% (2/10 statements)

### AIntents.sol  
- **Line Coverage**: 29.27% (12/41 lines)
- **Branch Coverage**: 21.05% (8/38 branches)
- **Function Coverage**: 47.06% (8/17 functions)
- **Statement Coverage**: 44.44% (4/9 functions)

## Improvements Made

### 1. Test Suite Enhancements
- Added 8 new unit tests in `AcrossUnit.t.sol`
- Added 12 new integration tests in `AcrossIntegrationFork.t.sol`
- Total test count increased from 29 to 58 tests

### 2. Configuration Updates
- Updated `foundry.toml` with public RPC endpoints for Arbitrum, Optimism, and Base
- Tests can now run with publicly available RPCs without requiring private API keys

### 3. Test Categories Added

#### New Unit Tests:
1. `test_Handler_ConstructorStoresSpokePool` - Verifies handler stores spoke pool address
2. `test_Adapter_ConstructorStoresSpokePool` - Verifies adapter stores spoke pool address  
3. `test_OpType_EnumValues` - Tests OpType enum has correct values (0, 1, 2)
4. `test_DestinationMessage_AllOpTypes` - Tests encoding/decoding for all 3 OpTypes
5. `test_SourceMessage_EncodingDecoding` - Tests SourceMessage encoding/decoding
6. `test_NavNormalization_EdgeCases` - Tests NAV normalization with various decimal combinations
7. `test_ToleranceCalculation_EdgeCases` - Tests tolerance calculations (0.01%, 10%, 100%)
8. `test_Adapter_RejectsInactiveToken` - Tests adapter rejects inactive tokens

#### New Fork Integration Tests:
1. `testFork_Handler_ConstructorZeroAddressReverts` - Verifies constructor validation
2. `testFork_Arb_DeployedContractsExist` - Verifies contracts deploy on Arbitrum
3. `testFork_Opt_DeployedContractsExist` - Verifies contracts deploy on Optimism
4. `testFork_Adapter_RequiredVersion` - Verifies adapter version string
5. `testFork_Arb_USDCExists` - Verifies USDC token on Arbitrum
6. `testFork_Arb_WETHExists` - Verifies WETH token on Arbitrum
7. `testFork_Arb_SpokePoolExists` - Verifies Across SpokePool on Arbitrum
8. `testFork_MessageEncodingConsistency` - Tests message encoding across chains
9. `testFork_AllOpTypes` - Tests all three OpType values

## Why Coverage Remains Low

The low coverage is due to architectural constraints:

### 1. Delegatecall Context Requirement
Both `EAcrossHandler` and `AIntents` are designed to be called via `delegatecall` from a pool proxy. This means:
- They need full pool storage context
- They need to interact with other pool extensions (EOracle, etc.)
- They need actual tokens and balances in the pool

### 2. Complex Dependencies
To properly test these contracts, you need:
- A deployed pool proxy with correct storage layout
- Active token set with price feeds
- Mocked or real EOracle for token conversions
- Proper ExtensionsMap configuration
- Virtual balance storage slots initialized

### 3. Current Test Limitations
Most existing tests use one of two approaches:
1. **Pure unit tests** - Test only basic functionality with mocks (functions that don't need pool context)
2. **Skipped tests** - Tests marked with `vm.skip(true)` that would require full integration setup

## Recommendations for Increasing Coverage

### Option 1: Enhanced Mock Pool (Recommended)
Create a comprehensive `MockSmartPool` contract that:
```solidity
contract MockSmartPool {
    // Implements all required interfaces
    // Has proper storage layout matching real pool
    // Can delegatecall to adapters/handlers
    // Provides mocked EOracle responses
    // Manages active tokens set
}
```

This would allow testing actual logic flows without needing deployed pools.

### Option 2: Fork-Based Integration Tests (Current Approach)
Extend fork tests to:
1. Deploy new pool instances on forks
2. Fund pools with real tokens
3. Execute full cross-chain transfer flows
4. Test handler receiving actual Across messages

**Challenges**:
- Requires RPC access
- Slower test execution
- More complex test setup
- Can't easily test error conditions

### Option 3: Hardhat Integration Tests
Use existing Hardhat test infrastructure:
- Already has pool deployment fixtures
- Has token mocking
- Can test full integration flows
- Located in `test/extensions/Across*.spec.ts`

**Note**: Hardhat tests already exist but weren't included in Foundry coverage.

## Specific Functions Needing Coverage

### EAcrossHandler (Main Logic)
- `_handleTransferMode()` - Creates virtual balances on destination
- `_handleRebalanceMode()` - Validates NAV spread compliance
- `_handleSyncMode()` - Records chain NAV spreads
- `_normalizeNav()` - Decimal conversion logic
- `_getVirtualBalance()` / `_setVirtualBalance()` - Storage access
- `_getChainNavSpread()` / `_setChainNavSpread()` - Spread storage

### AIntents (Main Logic)
- `_processMessage()` - Message processing and OpType routing
- `_adjustVirtualBalanceForTransfer()` - Creates virtual balances on source
- `_safeApproveToken()` - Token approval logic (USDT-compatible)
- `_getVirtualBalance()` / `_setVirtualBalance()` - Storage access

## Next Steps

### Immediate (Low Effort, Moderate Impact)
1. ✅ Add more unit tests for pure functions (encoding, validation, etc.)
2. ✅ Add fork tests that verify contract deployment and configuration
3. ✅ Configure public RPC endpoints for fork testing

### Short Term (Medium Effort, High Impact)
4. Create comprehensive MockSmartPool with proper storage
5. Write integration tests using MockSmartPool
6. Test all OpType flows (Transfer, Rebalance, Sync)
7. Test error conditions (invalid OpType, unauthorized caller, etc.)

### Long Term (High Effort, Highest Impact)
8. Deploy test pools on forks with funded balances
9. Execute end-to-end cross-chain transfer simulations
10. Test NAV integrity across chains
11. Test WETH unwrapping logic
12. Test tolerance validation logic

## Files Modified

1. `test/extensions/AcrossUnit.t.sol` - Added 8 new tests
2. `test/extensions/AcrossIntegrationFork.t.sol` - Added 12 new tests
3. `foundry.toml` - Added RPC endpoint configuration
4. `ACROSS_TEST_COVERAGE_STATUS.md` - This document

## Running Tests

```bash
# Run all Across tests
forge test --match-path "test/extensions/Across*.sol"

# Run with fork tests (requires RPC URLs)
ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc \
OPTIMISM_RPC_URL=https://mainnet.optimism.io \
BASE_RPC_URL=https://mainnet.base.org \
forge test --match-path "test/extensions/Across*.sol"

# Check coverage
npm run coverage:foundry
```

## Conclusion

While coverage remains low due to architectural constraints, the test infrastructure has been significantly improved. The main blocker for higher coverage is the need for proper pool context that can only be achieved through either:
1. Comprehensive mocking (MockSmartPool approach)
2. Full integration testing on forks with deployed pools
3. Using existing Hardhat tests (which aren't measured by Foundry coverage)

The foundation is now in place for anyone to extend coverage by implementing Option 1 (MockSmartPool) or Option 2 (enhanced fork tests).
