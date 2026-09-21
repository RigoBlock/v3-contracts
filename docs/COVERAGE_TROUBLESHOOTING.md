# Coverage Troubleshooting Guide

> **Hardhat 3 migration note**: `yarn coverage:hardhat` now uses Hardhat 3's built-in
> coverage (`hardhat test --coverage`), which writes `coverage/lcov.info` (plus an HTML
> report) that CI uploads to Codecov alongside the Foundry report. The old
> `solidity-coverage` plugin is no longer needed and was removed.

## Coverage Architecture (Foundry)

`scripts/foundry-coverage.sh` runs **one** `forge coverage` invocation over all tests
(unit + fork together). This was a deliberate change (2026-09) away from a 3-run split
(library / non-fork / fork + lcov merge) that needed per-file include/exclude lists and
a "contract name must contain Fork" convention — both rotted with every new test file.

Measured on forge 1.8.1 (the version CI pins), the single invocation covers a **superset**
of the lines the split covered (2 extra lines, none lost). Forge's coverage quirks in
this area have a long public history — the canonical reports are all **closed** now
(coverage was reworked several times since), but they document the problem class:
[foundry#7054](https://github.com/foundry-rs/foundry/issues/7054) and
[foundry#2826](https://github.com/foundry-rs/foundry/issues/2826) (library coverage
attribution — per-line HIT COUNTS can still undercount when a library is inlined into
a contract deployed by several suites; verified on 1.8.1: `GmxAdapterLib` recorded 69
hits where 81 executions happened. Only the count is affected — executed lines are
never marked uncovered, which is all Codecov's line view needs),
[foundry#4952](https://github.com/foundry-rs/foundry/issues/4952) (invariant tests
pathologically slow under coverage, hence the two fuzz exclusions), and
[foundry#6442](https://github.com/foundry-rs/foundry/issues/6442) (fork + coverage
flakiness). Behavior on the pinned version is what matters; re-measure before
changing this setup.

The only exclusions are stable ones, documented in the script header: the
`test/debug/**` folder, the two local-only-network fork files (`PolygonFork`,
`A0xRouterUnichainFork`), and the two fuzz contracts. **Do not add per-file
exclusions** when adding tests — if coverage looks wrong, the cause is almost always
upstream of filtering: a failed/blocked CI run whose Codecov page still shows an older
commit's data, or fork tests failing under RPC pressure (see below).

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

#### 1. **Explicit Failure Detection + Proper Error Propagation** ([scripts/foundry-coverage.sh](../scripts/foundry-coverage.sh)) - **THE REAL FIX (2024-era forge)**

Older forge releases (0.2.0 era, when this incident happened) **exited 0 even when
tests failed**, so failing fork tests produced an all-zero-line coverage report that
was uploaded to Codecov silently (lines covered only by fork tests showed as
uncovered). The coverage script pipes forge's output through a guard that fails the
step when any test failed:

```bash
forge coverage ... 2>&1 | tee "$LOG"
if grep -Eq "([1-9][0-9]* failed|Failing tests)" "$LOG"; then
  echo '❌ ERROR: forge coverage had failing tests' >&2
  exit 1
fi
```

> Verified 2026-09 on forge 1.8.1 (the version CI pins): `forge coverage` now exits 1
> when a test fails, so the grep guard is defense-in-depth rather than load-bearing.
> Keep it anyway — it costs nothing and protects against regressions in future forge
> versions.
>
> History note: this detection existed in the `coverage:foundry` package.json
> one-liner but was lost in commit `2bee2d53` ("ci: fix coverage caching") when
> coverage moved to the split script, while this doc still described it as
> implemented. It is now restored in `scripts/foundry-coverage.sh`. When changing
> the coverage setup, keep a failure-detection guard in whichever command CI runs.

**Result:** fork tests fail (usually RPC rate limits) → CI step fails → nothing is
uploaded → retry the job. Bad coverage can no longer reach Codecov silently. If
Codecov shows unexpectedly uncovered lines, first check the CI run for that commit:
a failed or still-running coverage step means the page is showing an older commit's
data (`carryforward: false` in `.codecov.yml` means nothing is carried over, so a
missing upload leaves the previous state visible).

#### 2. **Fork Data Cache** ([.github/workflows/ci.yml](../.github/workflows/ci.yml))

Fork state at the pinned blocks in [ForkBlocks.sol](../contracts/test/ForkBlocks.sol)
is immutable, so CI caches `~/.foundry/cache/rpc` and reuses it across runs:

```yaml
- name: Cache Foundry fork data
  uses: actions/cache@v6
  with:
    path: ~/.foundry/cache/rpc
    key: ${{ runner.os }}-foundry-rpc-v3-${{ hashFiles('contracts/test/ForkBlocks.sol') }}
```

History: this cache existed from early 2025 but was commented out on 2026-01-15
(commit `ea67665d`, "temporary not cache fork data") as an isolation step while
debugging the coverage inconsistencies, and the coverage step was switched to
`yarn coverage:clean` in the same commit. The debugging concluded but the
"temporary" setup was never reverted — for ~8 months every CI run wiped the fork
cache mid-job (`coverage:clean` deletes `~/.foundry/cache/rpc`) and re-fetched all
fork state from RPC in one cold burst, which is the main source of RPC pressure and
intermittent fork-test failures. Both are restored now: the coverage step runs
`yarn coverage:all` again, and the persistent cache is re-enabled (key bumped
v2 → v3 after the long disable).

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
3. **Consider retrying the job**: transient RPC failures are the usual cause — a
   re-run typically passes (the fork-state cache is keyed on `ForkBlocks.sol`, so a
   re-run reuses cached fork state and makes fewer RPC calls).

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
- [ ] Cache fork state in CI for reuse
