# Coverage Troubleshooting Guide

## Inconsistent Coverage in CI

### Problem

Coverage reports show inconsistent results between CI runs:
- Sometimes: **95%+** coverage
- Sometimes: **82%** coverage  
- Locally: Consistent **95%+**

### Root Cause

The issue is caused by **fork tests silently failing during `forge coverage`**:

1. **`forge coverage` exits 0 even when tests fail** - This is a Foundry behavior
2. **Failed fork tests contribute 0% coverage** for the files they would test
3. **Fork tests fail due to RPC issues**: Rate limiting, timeouts, connection errors
4. **The failures are intermittent**, creating the unpredictable pattern:
   - When RPC is fast/responsive → fork tests pass → 95%+ coverage uploaded ✅
   - When RPC is slow/rate-limited → fork tests fail silently → 82% coverage uploaded ❌
   - **Without failure detection, both reports were uploaded to Codecov**

### Why Every Other Commit?

The pattern wasn't actually about cache - it was about **RPC timing variability**:
- Some runs hit RPC rate limits or timeouts → fork tests fail → bad coverage
- Other runs get through quickly → fork tests pass → good coverage
- The alternating pattern was just coincidence from intermittent RPC issues

### Evidence

From the Foundry coverage report when fork tests fail:

```
⚡ FOUNDRY COVERAGE:
   Lines: 462/2727 (16.94%)
```

**16.94% is abnormally low** - normal is 40-50% for Foundry-specific tests.

When you see this low percentage, fork tests have failed, causing files like:
- `NavView.sol` → 0% coverage (should have ~80%)
- `ENavView.sol` → partial coverage
- Other files tested by fork tests → reduced coverage

### Solutions Implemented

#### 1. **Explicit Failure Detection** ([package.json](../package.json)) - **THE REAL FIX**

```bash
# forge coverage exits 0 even with test failures, so we check the output
forge coverage ... 2>&1 | tee /tmp/forge_coverage.log && \
if grep -q 'failing test' /tmp/forge_coverage.log; then 
  echo '❌ ERROR: Fork tests failed'; 
  exit 1; 
fi
```

**This is the critical fix**: The CI job now **fails immediately** if fork tests fail, preventing bad coverage from being uploaded to Codecov.

#### 2. **Per-PR Fork Cache** ([.github/workflows/ci.yml](../.github/workflows/ci.yml))

```yaml
# Cache shared across all commits in the same PR/branch
# Avoids expensive RPC re-syncing on every commit
key: ${{ runner.os }}-foundry-forks-${{ github.head_ref || github.ref_name }}
restore-keys: |
  ${{ runner.os }}-foundry-forks-main
  ${{ runner.os }}-foundry-forks-development
```

This prevents unnecessary RPC calls while still refreshing cache when switching PRs/branches.

#### 3. **Codecov Merge Configuration** ([.codecov.yml](../.codecov.yml))

Ensures Codecov doesn't carry forward stale coverage from previous commits:

```yaml
flag_management:
  individual_flags:
    - name: hardhat
      carryforward: false  # Don't reuse old coverage
    - name: foundry
      carryforward: false
```

### What This Fixes

Now when RPC issues occur:
- **Fork tests fail** → coverage script detects "failing test" in output
- **Script exits with error code 1** → CI job fails with clear error message  
- **No bad coverage uploaded** → Codecov only receives good reports (95%+)
- **Developer sees failure** → can retry the CI run

**Before this fix:**
- Fork tests failed silently → 82% coverage uploaded to Codecov ❌
- Appeared as coverage regression when it was actually RPC timing

**After this fix:**
- Fork tests fail → CI fails visibly → retry → only good reports reach Codecov ✅

### Verification

After running `yarn coverage:all`, check:

1. **Foundry coverage percentage**: Should be **40-50%**, not 16%
2. **NavView.sol missing lines**: Should be ~5-10 lines, not 30+
3. **Warning message**: Should NOT appear if fork tests succeeded

### When Fork Tests Fail in CI

If you see the warning or low Foundry coverage:

1. **Check RPC endpoint status** - Are the secrets properly configured?
2. **Check rate limits** - Has the RPC provider throttled requests?
3. **Consider alternative**:
   ```yaml
   # In .github/workflows/ci.yml, temporarily use no-forks version:
   run: yarn coverage:setup && yarn coverage:hardhat && yarn coverage:foundry:no-forks && ...
   ```

### Local Testing

To simulate fork test failure locally:

```bash
# Clear RPC URL and run coverage
MAINNET_RPC_URL="" forge coverage --match-path 'test/extensions/ENavViewFork.t.sol'
# Result: "vm.createSelectFork: could not instantiate forked environment"
```

To verify fork tests work:

```bash
forge test --match-path 'test/extensions/ENavViewFork.t.sol' -vv
# Should pass if RPC_URL is configured
```

### Understanding the Coverage Reports

**Hardhat Coverage** (87.48% in example):
- Unit tests for protocol, staking, governance
- No fork tests (different test suite)
- Stable and consistent

**Foundry Coverage** (16.94% when broken, ~45% when working):
- Integration and fork tests
- Tests Foundry-specific features
- **Sensitive to RPC availability**

**Combined Coverage** (Codecov aggregates both):
- When Foundry works: **95%+**
- When Foundry fails: **82%** (Hardhat alone can't cover fork-tested code)

### Files Affected by Fork Test Failures

Primary impacts when fork tests fail:

- `contracts/protocol/libraries/NavView.sol` - **Major impact** (ENavViewFork.t.sol)
- `contracts/protocol/extensions/ENavView.sol` - Partial impact
- `contracts/protocol/extensions/ECrosschain.sol` - Some coverage loss
- `contracts/protocol/core/actions/MixinPoolValue.sol` - Edge cases uncovered

### Best Practices

1. **Always check Foundry % in CI logs** before merging
2. **Don't panic at 82% coverage** - check if it's RPC-related
3. **Retry CI if coverage drops** - transient RPC failures are common
4. **Monitor RPC provider status** during CI runs
5. **Consider upgrading RPC plan** if failures persist

### Related Issues

- Fork tests require mainnet state at specific blocks
- Coverage instrumentation makes tests slower, increasing timeout risk
- Free RPC tiers have rate limits (e.g., Infura: 100k req/day)
- Multiple concurrent CI jobs can hit rate limits

### Future Improvements

Consider:
- [ ] Dedicated RPC endpoint for CI
- [ ] Local Anvil fork state snapshots (faster, no RPC needed)
- [ ] Separate coverage job for fork tests
- [ ] Cache fork state in CI for reuse
- [ ] Split coverage into "unit" and "fork" categories
