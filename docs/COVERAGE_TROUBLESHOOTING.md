# Coverage Troubleshooting Guide

> **Hardhat 3 migration note**: `yarn coverage:hardhat` now uses Hardhat 3's built-in
> coverage (`hardhat test mocha --coverage` — mocha specs only; Foundry owns all
> Solidity tests), which writes `coverage/lcov.info` (plus an HTML
> report) that CI uploads to Codecov alongside the Foundry report. The old
> `solidity-coverage` plugin is no longer needed and was removed.
>
> Note: `hardhat test mocha --coverage` still reports zero-hit entries for every
> compiled contract (Hardhat instruments all of `contracts/` regardless of which
> tests run). Both reports are uploaded **raw** (no client-side filtering) — see
> "Raw uploads" below for why.

## Coverage Architecture (Foundry)

`yarn coverage:foundry` runs **one** `forge coverage` invocation over all tests
(unit + fork together), natively configured: exclusions live in `foundry.toml`
`[profile.coverage]` (`no_match_path`, `no_match_contract`, `no_match_coverage`) and
the command is a two-step native flow (`FOUNDRY_PROFILE=coverage forge build` +
`FOUNDRY_PROFILE=coverage forge coverage --report lcov`, tee'd to
`/tmp/forge_coverage.log`). This was a deliberate change (2026-09) away from a 3-run
split (library / non-fork / fork + lcov merge) that needed per-file include/exclude
lists and a "contract name must contain Fork" convention — both rotted with every new
test file.

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

## Coverage Architecture (Foundry)

### The deployCode instrumentation gotcha (native profile prebuild)

Several suites deploy contracts via `deployCode("out/<file>.json", ...)` — the
prebuilt artifact on disk — instead of importing the source. The affected
contracts are the ones that must compile with a different solc than the 0.8.28
test files (e.g. `AUniswapRouter.sol`, pinned to 0.8.37 — see commit `8d4237f5`)
plus fixtures that reuse artifacts (`Authority`, `PoolRegistry`, `RigoblockPool-
ProxyFactory`, `Staking`, `GrgVault`, `AStaking`, mocks, ...).

`forge coverage` compiles the project **optimizer-off in memory** (that build is
never written to `out/` — verified on forge 1.8.3) and attributes execution
hits by matching deployed bytecode against the instrumented source maps. The
on-disk `out/` artifacts are built **with the optimizer on** (default profile),
so their bytecode hashes differently and every `deployCode`-deployed contract
records **zero hits** for its whole file, no matter how heavily the tests
exercise it. Observed on a full run before the fix: `AUniswapRouter.sol` 0/110
DA lines, `AUniswapDecoder.sol` 0/246, `Authority.sol` 0/39, `Staking.sol` 0/4,
`GrgVault.sol` 0/43 — all while the corresponding fork/unit tests passed.

The fix is fully native, no artifact swapping: `[profile.coverage]` in
`foundry.toml` sets `optimizer = false` and inherits everything else from
`[profile.default]` (including the `compilation_restrictions` / 0.8.37 isolated
job). `yarn coverage:foundry` first runs `FOUNDRY_PROFILE=coverage forge build`,
which writes optimizer-off artifacts into the **same `out/` dir** that
`deployCode` reads (test files hardcode `out/` paths — the out dir must NOT
change). Those artifacts are byte-identical to forge coverage's internal build,
so hits are attributed. Verified on forge 1.8.3: the router fork suite alone
records 87/110 (router) + 96/246 (decoder) hit DA lines instead of 0. Forge
caches per compilation settings, so a later default-profile `forge build` /
`forge test` transparently rebuilds the optimizer-on artifacts — the prebuild
does not poison normal runs.

Guard rail: `scripts/analyze-coverage.sh` (guard 3) fails the CI step if the
Foundry report shows zero total or zero hit DA lines for `AUniswapRouter.sol` /
`AUniswapDecoder.sol` — the canary for this regression.

Known residual (2026-09-25): `Authority.sol`, `Staking.sol`, `GrgVault.sol`,
and `StakingProxy.sol` still record 0 hits even with matching artifacts, while
`PoolRegistry.sol` — deployed by the same fixture via the same `deployCode`
path, same solc 0.8.17 pragma — attributes correctly. This is an
Authority-family-specific foundry source-map quirk, not the optimizer
mismatch (these zeros predate the fix and were never affected by it).
These files are covered by the Hardhat upload, so the merged Codecov view is
unaffected.

### Raw uploads (no client-side filtering)

Both lcov reports are uploaded to Codecov **exactly as the tools produce them**:
`./coverage/lcov.info` (Hardhat) and `./coverage/foundry_lcov.info` (Foundry).
No awk filtering, no zero-hit block removal, no per-file stripping — this is
deliberate: after Codecov-side upgrades we want to observe whether Codecov's own
union aggregation of the two raw reports is now correct on its own (it
union-merges per line and claims not to override report data —
docs.codecov.com/docs/merging-reports). Known consequence to watch for on the
Codecov UI: files covered only by Foundry (GMX contracts, `CrosschainLib`,
`Escrow`, `HyperliquidLib`) also appear in the Hardhat upload with zero hits,
and `AUniswapRouter.sol`/`AUniswapDecoder.sol` appear in both — per-flag views
may therefore disagree with the merged view. If that proves confusing, the
decision to filter (or not) is revisited with fresh Codecov behavior data, not
restored blindly.

### `anvil_nodeInfo` HTTP 400 spam on fork creation (upstream, harmless)

Every `vm.createSelectFork` makes forge send an `anvil_nodeInfo` probe to the
real RPC endpoint (foundry 1.8.x `AnvilNodeInfoProbe` in
`foundry_evm_core::opts`, added by foundry-rs/foundry#16151/#16295 to detect
Anvil-backed endpoints). Public providers (Alchemy, ...) do not implement this
anvil-only method and answer with HTTP 400 "Unsupported method: anvil_nodeInfo".
This is a **best-effort probe**: forge treats the failure as "not an Anvil
endpoint" and continues normally. There is **no flag, env var, or config key**
to disable it (checked `forge test/coverage --help` and the foundry source on
1.8.3).

Crucially, the probe is **volume, not data**: fork *state* (the heavy RPC
fetches — storage, code, logs at the pinned blocks) is disk-cached in
`~/.foundry/cache/rpc` and CI-cached (key includes the `ForkBlocks.sol` hash),
so state is fetched at most once per pinned block per cache generation. The
400s fire once per `createSelectFork` **call** regardless of caching. Impact:
one extra lightweight 400 request per fork creation — noisy in RPC dashboards,
functionally harmless; no fork test result is affected. Do not try to "fix" it
by pinning an older forge — the probe is intentional upstream behavior.

### Fork-initialization hygiene (probe-volume reduction)

Because the probe fires per `createSelectFork` call, redundant fork creation is
the only lever we control. Rule: **create each fork once per test file, in
`setUp`, and store the fork id; tests that need to return to it call
`vm.selectFork(id)`** — never a second `createSelectFork` of the same chain+block.
Audit result (2026-09-25): every fork file already initializes once in `setUp`,
with one exception that was refactored — `AGmxV2Fork.t.sol` re-created the
arbitrum fork inside two test bodies (3 call sites → 1). Files left with fork
creation outside `setUp`, all legitimate: `DonateNavInvariantTest.t.sol` (single
test that needs mainnet; the rest of the file runs on the local chain, so a
`setUp`-level fork would change what every other test runs against) and
`test/fixtures/RealDeploymentFixture.sol` (the two mainnet calls are in
mutually-exclusive single-chain / multi-chain branches). Genuinely multi-chain
tests (mainnet+base etc.) are correct by design and untouched.

### `anvil_nodeInfo` HTTP 400 spam on fork creation (upstream, harmless)

Every `vm.createSelectFork` makes forge send an `anvil_nodeInfo` probe to the
real RPC endpoint (foundry 1.8.x `AnvilNodeInfoProbe` in
`foundry_evm_core::opts`, added by foundry-rs/foundry#16151/#16295 to detect
Anvil-backed endpoints). Public providers (Alchemy, ...) do not implement this
anvil-only method and answer with HTTP 400 "Unsupported method: anvil_nodeInfo".
This is a **best-effort probe**: forge treats the failure as "not an Anvil
endpoint" and continues normally. There is **no flag, env var, or config key**
to disable it (checked `forge test/coverage --help` and the foundry source on
1.8.3). Impact: one extra lightweight 400 request per fork creation — noisy in
RPC dashboards, functionally harmless; no fork test result is affected. Do not
try to "fix" it by pinning an older forge — the probe is intentional upstream
behavior.

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

#### 1. **Explicit Failure Detection + Proper Error Propagation** ([scripts/analyze-coverage.sh](../scripts/analyze-coverage.sh)) - **THE REAL FIX (2024-era forge)**

Older forge releases (0.2.0 era, when this incident happened) **exited 0 even when
tests failed**, so failing fork tests produced an all-zero-line coverage report that
was uploaded to Codecov silently (lines covered only by fork tests showed as
uncovered). The analyzer greps the tee'd forge output and fails the step when any
test failed:

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
> implemented. It is now restored in `scripts/analyze-coverage.sh`. When changing
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
      carryforward: false # Don't reuse old coverage
    - name: foundry
      carryforward: false
```

#### 4. **Fail-Loud Analyzer Guards** ([scripts/analyze-coverage.sh](../scripts/analyze-coverage.sh))

Codecov union-merges uploads line-by-line and "does not override report data for
multiple uploads" (docs.codecov.com/docs/merging-reports), so the pipeline relies on
two separate raw uploads (`hardhat` and `foundry` flags) and no client-side merging
or filtering (see "Raw uploads" above). The analyzer script is **read-only**: it
runs no coverage, writes no reports — it reads the two lcov files plus the tee'd
forge log and prints the aggregated analysis (per-file missing lines, lines missed
by BOTH suites). On top of printing, it enforces four guards (exit 1 → CI step
fails → nothing reaches Codecov):

1. **Failure grep** — the forge log must not contain failing tests (forge
   historically exited 0 on failure; see solution 1).
2. **Sentinel fork suites** — at least one known fork suite
   (`AUniswapRouter(Execute|ModifyLiquidities)?ForkTest`, `AGmxV2ForkTest`,
   `A0xRouterForkTest`) must appear in the forge output, proving forks were
   actually created against the RPC endpoints. Covers suites silently never
   running via a future exclusion/path change or a fork-creation error forge
   reports without counting as a test failure.
3. **deployCode instrumentation canary** — the Foundry report must show non-zero
   hit AND total DA lines for `AUniswapRouter.sol` and `AUniswapDecoder.sol`,
   proving the `[profile.coverage]` prebuild still produces artifacts matching
   forge coverage's internal build.
4. **Fork-coverage floor** — the Foundry report must contain at least 1000 DA hit
   lines (a normal full run is ~1800+; the historical bad run with fork suites
   silently absent produced 462).

**How to verify a Codecov report is complete:** the analyze step prints each guard
result and the Foundry hit-line count vs the floor.
On the Codecov side, the commit totals should show `sessions: 2` (both uploads
received; query
`https://api.codecov.io/api/v2/gh/RigoBlock/repos/v3-contracts/commits/<sha>/`).
If a file still looks wrongly uncovered with both sessions present, re-run the
CI job before suspecting the tests — fork-branch coverage of a few lines can
legitimately flip between runs (time- and price-dependent branches).

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
