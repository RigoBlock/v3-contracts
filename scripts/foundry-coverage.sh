#!/bin/bash
set -e

# Foundry coverage with fork/non-fork split and merge
#
# Problem: Foundry's lcov reporter does not reliably merge line hits (DA records)
# when fork and non-fork tests run in the same invocation. Running them separately
# and merging with lcov solves that.
#
# Workaround for Foundry coverage bug: if ~/.foundry/cache/rpc has just been
# cleared, the very first `forge coverage` run corrupts line-level coverage for
# internal libraries inlined into non-fork test contracts (e.g. HyperliquidLib),
# recording DA:0 even though the code is executed. Running one fast test before
# the split coverage steps warms up Foundry's instrumentation and avoids the bug.
#
# IMPORTANT: this script is intended to run with a warm RPC cache. If you must
# clear the cache, do it before this script and let the warm-up step below run.

COVERAGE_FILTER='--no-match-coverage "mocks/|examples/|test/|tokens/|utils/"'

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "          FOUNDRY COVERAGE (split fork/non-fork)"
echo "════════════════════════════════════════════════════════════════"
echo ""

mkdir -p coverage

# ─── Step 0: Full build once ──────────────────────────────────────────
# Foundry's coverage instrumentation reuses the incremental build cache. When
# multiple `forge coverage` invocations run back-to-back, a cold or partial
# cache can drop coverage probes for library files that are inlined into many
# contracts (e.g. HyperliquidLib, GmxLib). Running a full `forge build` first
# warms the cache and guarantees every artifact exists, so the subsequent
# coverage runs do not need partial rebuilds that corrupt instrumentation.
# This is the generic replacement for per-contract isolated runs.
echo "⚡ Step 0/4: Building all contracts once..."

forge build

echo "   ✅ Full build complete"

# ─── Step 0b: Warm-up run to work around Foundry instrumentation bug ──
# After a cold RPC cache, Foundry's first coverage run produces DA:0 for some
# inlined internal libraries. Running a single fast non-fork test first warms up
# the coverage instrumentation so the subsequent split steps record real line hits.
echo "⚡ Step 0b/4: Warming up coverage instrumentation..."

forge test --match-contract AHyperliquidUnit --match-test testDeployRevertsOnNonHyperEVM >/dev/null 2>&1 || true

echo "   ✅ Warm-up complete"

# ─── Step 1: Library unit tests (isolated run) ────────────────────────
# Internal libraries are inlined into production contracts. When all non-fork
# tests run together, forge's coverage probe system records the last-written hit
# count per source line, and production-contract deployments that don't exercise
# every library path overwrite hits from the library harness tests with zeros.
# Running the library tests in isolation guarantees their hits are captured and
# then added during the merge step.
echo "⚡ Step 1/4: Running library unit test coverage (isolated)..."

rm -f lcov.info
forge coverage \
  --no-match-coverage "mocks/|examples/|test/|tokens/|utils/" \
  --match-path 'test/{libraries/*.t.sol,extensions/AHyperliquidUnit.t.sol}' \
  --no-match-contract "Fork|DelegationLibFuzz" \
  --report lcov

mv lcov.info /tmp/foundry_library_lcov.info
echo "   ✅ Library unit test coverage generated"

# ─── Step 2: Non-fork tests ─────────────────────────────────────────
echo "⚡ Step 2/4: Running non-fork test coverage..."

rm -f lcov.info
forge coverage \
  --no-match-coverage "mocks/|examples/|test/|tokens/|utils/" \
  --no-match-contract 'A0xRouterForkTest|AHyperliquidForkTest|ENavViewForkTest|AIntentsRealForkTest|EscrowWorkingTest|VSOnlyModelTest|AIntentsPerformanceAttributionAnalysisTest|PolygonForkTest|PoolDonateTest|AGmxV2ForkTest|A0xRouterUnichainForkTest|AUniswapForkTest|BscPoolUpgradeDebugTest|DelegationLibFuzz|ECrosschainFuzzTest' \
  --report lcov

mv lcov.info /tmp/foundry_nofork_lcov.info
echo "   ✅ Non-fork coverage generated"

# ─── Step 3: Fork tests ─────────────────────────────────────────────
echo "⚡ Step 3/4: Running fork test coverage..."

rm -f lcov.info
forge coverage \
  --no-match-coverage "mocks/|examples/|test/|tokens/|utils/" \
  --match-contract 'A0xRouterForkTest|AHyperliquidForkTest|ENavViewForkTest|AIntentsRealForkTest|EscrowWorkingTest|VSOnlyModelTest|AIntentsPerformanceAttributionAnalysisTest|PoolDonateTest|AGmxV2ForkTest|AUniswapForkTest' \
  --no-match-contract 'DelegationLibFuzz|ECrosschainFuzzTest' \
  --report lcov

mv lcov.info /tmp/foundry_fork_lcov.info
echo "   ✅ Fork coverage generated"

# ─── Step 4: Merge ──────────────────────────────────────────────────
echo "⚡ Step 4/4: Merging coverage reports..."

lcov \
  --add-tracefile /tmp/foundry_nofork_lcov.info \
  --add-tracefile /tmp/foundry_fork_lcov.info \
  --add-tracefile /tmp/foundry_library_lcov.info \
  --output-file coverage/foundry_lcov.info \
  --rc branch_coverage=1

# Show summary
library_lines=$(grep -c "^DA:" /tmp/foundry_library_lcov.info || echo "0")
library_hit=$(grep "^DA:" /tmp/foundry_library_lcov.info | grep -v ",0$" | wc -l || echo "0")
nofork_lines=$(grep -c "^DA:" /tmp/foundry_nofork_lcov.info || echo "0")
nofork_hit=$(grep "^DA:" /tmp/foundry_nofork_lcov.info | grep -v ",0$" | wc -l || echo "0")
fork_lines=$(grep -c "^DA:" /tmp/foundry_fork_lcov.info || echo "0")
fork_hit=$(grep "^DA:" /tmp/foundry_fork_lcov.info | grep -v ",0$" | wc -l || echo "0")
merged_lines=$(grep -c "^DA:" coverage/foundry_lcov.info || echo "0")
merged_hit=$(grep "^DA:" coverage/foundry_lcov.info | grep -v ",0$" | wc -l || echo "0")

echo ""
echo "   📊 Coverage summary:"
echo "   Library:    $library_hit/$library_lines lines"
echo "   Non-fork:   $nofork_hit/$nofork_lines lines"
echo "   Fork:       $fork_hit/$fork_lines lines"
echo "   Merged:     $merged_hit/$merged_lines lines"

# Cleanup (keep intermediate tracefiles for debugging)
# rm -f /tmp/foundry_library_lcov.info /tmp/foundry_nofork_lcov.info /tmp/foundry_fork_lcov.info

echo ""
echo "   ✅ Merged foundry coverage written to coverage/foundry_lcov.info"
echo ""
