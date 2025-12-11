# Across Bridge Integration - Test Suite

## Overview

This directory contains comprehensive tests for the Across bridge integration with Rigoblock smart pools. Tests are organized into unit tests and integration tests with fork testing.

## Test Files

### 1. AcrossUnit.t.sol
**Purpose:** Unit tests for individual components without external dependencies.

**Tests:**
- Contract deployment verification
- Message encoding/decoding
- NAV normalization logic
- Tolerance calculation
- Storage slot verification
- Enum value validation
- Fuzz testing for mathematical operations

**Run:**
```bash
forge test --match-contract AcrossUnitTest -vv
```

### 2. AcrossIntegration.t.sol
**Purpose:** Integration tests with fork testing to simulate cross-chain transfers.

**Tests:**
- Transfer mode: NAV unchanged on both chains
- Rebalance mode: NAV verification across chains
- NAV deviation rejection
- Token without price feed rejection
- Native currency unwrapping
- Token recovery via speedUpV3Deposit
- Virtual balance tracking
- Direct call rejection

**Requirements:**
- RPC URLs configured in `.env`:
  ```
  ARBITRUM_RPC_URL=https://...
  OPTIMISM_RPC_URL=https://...
  BASE_RPC_URL=https://...
  ```

**Run:**
```bash
# Single chain fork test
forge test --match-contract AcrossIntegrationTest --match-test test_TransferMode -vv

# All integration tests (requires multiple RPC endpoints)
forge test --match-contract AcrossIntegrationTest -vvv
```

## Test Scenarios

### Transfer Mode Tests

**Scenario:** Cross-chain token transfer without NAV impact

1. **Source Chain:**
   - Call `depositV3` with Transfer mode message
   - Verify positive virtual balance created
   - Verify NAV remains unchanged

2. **Destination Chain:**
   - Across SpokePool transfers tokens to pool
   - Calls `handleV3AcrossMessage` via delegatecall
   - Handler creates negative virtual balance
   - Verify NAV remains unchanged

**Expected Result:** NAV is identical before/after on both chains.

### Rebalance Mode Tests

**Scenario:** Cross-chain rebalancing with NAV verification

1. **Source Chain:**
   - Call `depositV3` with Rebalance mode
   - Adapter calculates and stores source NAV in message
   - NAV changes naturally from token exit

2. **Destination Chain:**
   - Handler receives tokens and verifies destination NAV
   - NAV must be within specified tolerance of source NAV
   - Accounting for decimal differences

**Expected Result:** Transaction succeeds if NAV within tolerance, reverts otherwise.

### Error Cases

1. **Pool Doesn't Exist:**
   - Across reverts when trying to call handler on non-existent contract
   - Tokens remain claimable on source chain

2. **Token Without Price Feed:**
   - Handler reverts with `TokenWithoutPriceFeed`
   - Triggers Across failure, allows source recovery

3. **NAV Deviation Too High:**
   - Handler reverts with `NavDeviationTooHigh`
   - Tokens can be recovered on source chain

## Running Tests

### All Tests
```bash
forge test
```

### Specific Test File
```bash
forge test --match-path test/extensions/AcrossUnit.t.sol
forge test --match-path test/extensions/AcrossIntegration.t.sol
```

### Specific Test
```bash
forge test --match-test test_TransferMode_NavUnchanged -vvv
```

### With Gas Report
```bash
forge test --gas-report
```

### With Coverage
```bash
forge coverage --report lcov
```

### Fork Testing Options

**Arbitrum Fork:**
```bash
forge test --fork-url $ARBITRUM_RPC_URL --match-contract AcrossIntegrationTest
```

**Optimism Fork:**
```bash
forge test --fork-url $OPTIMISM_RPC_URL --match-contract AcrossIntegrationTest
```

**Multiple Forks (requires vm.createFork):**
```bash
# Tests handle fork selection internally
forge test --match-contract AcrossIntegrationTest -vvv
```

## Deployed Contract Addresses

Reference: https://docs.rigoblock.com/readme-2/deployed-contracts-v4

### Rigoblock (Same across chains unless specified)
- **Authority:** `0x7F427F11eB24f1be14D0c794f6d5a9830F18FBf1`
- **ExtensionsMapDeployer:** (TBD - deploy first)
- **SmartPool Implementation:** (from docs)

### Across SpokePool (Per Chain)
- **Arbitrum:** `0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A`
- **Optimism:** `0x6f26Bf09B1C792e3228e5467807a900A503c0281`
- **Base:** `0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64`

### Test Tokens
**Arbitrum:**
- USDC: `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`
- WETH: `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1`

**Optimism:**
- USDC: `0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85`
- WETH: `0x4200000000000000000000000000000000000006`

## Fuzz Testing

Tests include fuzz testing for:
- NAV normalization across different decimal combinations
- Tolerance calculations with various NAV values
- Edge cases with extreme values

**Run Fuzz Tests:**
```bash
forge test --match-test testFuzz -vv
```

**Adjust Fuzz Runs:**
```bash
# In foundry.toml
[fuzz]
runs = 10000
max_test_rejects = 100000
```

## Debugging

### Verbose Output
```bash
forge test -vvvv # Very verbose with traces
```

### Specific Test with Traces
```bash
forge test --match-test test_TransferMode -vvvv
```

### Gas Snapshots
```bash
forge snapshot
```

### Debug Specific Test
```bash
forge test --debug test_TransferMode_NavUnchanged
```

## Test Coverage Goals

- ✅ Unit test coverage: 100% for mathematical operations
- ✅ Integration coverage: All main flows (Transfer, Rebalance, Recovery)
- ✅ Error case coverage: All revert paths tested
- ✅ Fuzz testing: Edge cases for calculations
- ⏳ Multi-chain scenarios: Requires live forks or local nodes

## CI/CD Integration

### GitHub Actions Example
```yaml
- name: Run Foundry Tests
  run: |
    forge test --no-match-contract Integration # Unit tests only
    
- name: Run Integration Tests
  env:
    ARBITRUM_RPC_URL: ${{ secrets.ARBITRUM_RPC_URL }}
    OPTIMISM_RPC_URL: ${{ secrets.OPTIMISM_RPC_URL }}
  run: |
    forge test --match-contract Integration
```

## Known Limitations

1. **Fork Testing:** Requires external RPC endpoints with archive node support
2. **Cross-Chain:** Cannot truly test cross-chain transactions in single test (simulated via fork switching)
3. **Actual Across Fills:** Tests mock Across SpokePool behavior, not actual relayer fills
4. **Price Feeds:** Mock oracle responses in unit tests

## Future Improvements

1. Add tests for concurrent transfers
2. Test with real pool deployments on testnets
3. Add stress tests for high-frequency transfers
4. Test edge cases with pool upgrades during transfers
5. Add benchmarks for gas optimization

## Troubleshooting

### Issue: Fork tests fail with RPC errors
**Solution:** Ensure RPC URLs are configured and have archive node access:
```bash
# Test RPC connectivity
cast block-number --rpc-url $ARBITRUM_RPC_URL
```

### Issue: Tests timeout
**Solution:** Increase timeout in foundry.toml:
```toml
[profile.default]
timeout = 300000 # 5 minutes
```

### Issue: Out of gas errors
**Solution:** Increase gas limit:
```bash
forge test --gas-limit 30000000
```

## Support

For issues or questions:
1. Check Rigoblock documentation: https://docs.rigoblock.com
2. Review Across Protocol docs: https://docs.across.to
3. Open issue in repository with test logs
