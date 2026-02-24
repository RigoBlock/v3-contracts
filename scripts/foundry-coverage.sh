#!/bin/bash
set -e

# Foundry coverage with fork/non-fork split and merge
#
# Problem: Foundry's lcov reporter doesn't generate DA (line) entries for source
# files exercised only by fork tests when running alongside non-fork tests.
# Non-fork tests emit DA:N,0 for all lines, and fork tests only add FN/FNDA/BRDA
# without DA entries — so line coverage stays at 0%.
#
# Solution: Run fork and non-fork tests separately, then merge with lcov.

COVERAGE_FILTER='--no-match-coverage "mocks/|examples/|test/|tokens/|utils/"'

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "          FOUNDRY COVERAGE (split fork/non-fork)"
echo "════════════════════════════════════════════════════════════════"
echo ""

mkdir -p coverage

# ─── Step 1: Non-fork tests ─────────────────────────────────────────
echo "⚡ Step 1/3: Running non-fork test coverage..."

rm -f lcov.info
forge coverage \
  --no-match-coverage "mocks/|examples/|test/|tokens/|utils/" \
  --no-match-contract 'A0xRouterForkTest|ENavViewForkTest|AIntentsRealForkTest|EscrowWorkingTest|VSOnlyModelTest|AIntentsPerformanceAttributionAnalysisTest|PolygonForkTest|PoolDonateTest' \
  --report lcov

mv lcov.info /tmp/foundry_nofork_lcov.info
echo "   ✅ Non-fork coverage generated"

# ─── Step 2: Fork tests ─────────────────────────────────────────────
echo "⚡ Step 2/3: Running fork test coverage..."

rm -f lcov.info
forge coverage \
  --no-match-coverage "mocks/|examples/|test/|tokens/|utils/" \
  --match-contract 'A0xRouterForkTest|ENavViewForkTest|AIntentsRealForkTest|EscrowWorkingTest|VSOnlyModelTest|AIntentsPerformanceAttributionAnalysisTest|PoolDonateTest' \
  --report lcov

mv lcov.info /tmp/foundry_fork_lcov.info
echo "   ✅ Fork coverage generated"

# ─── Step 3: Merge ──────────────────────────────────────────────────
echo "⚡ Step 3/3: Merging coverage reports..."

lcov \
  --add-tracefile /tmp/foundry_nofork_lcov.info \
  --add-tracefile /tmp/foundry_fork_lcov.info \
  --output-file coverage/foundry_lcov.info \
  --rc branch_coverage=1

# Show summary
nofork_lines=$(grep -c "^DA:" /tmp/foundry_nofork_lcov.info || echo "0")
nofork_hit=$(grep "^DA:" /tmp/foundry_nofork_lcov.info | grep -v ",0$" | wc -l || echo "0")
fork_lines=$(grep -c "^DA:" /tmp/foundry_fork_lcov.info || echo "0")
fork_hit=$(grep "^DA:" /tmp/foundry_fork_lcov.info | grep -v ",0$" | wc -l || echo "0")
merged_lines=$(grep -c "^DA:" coverage/foundry_lcov.info || echo "0")
merged_hit=$(grep "^DA:" coverage/foundry_lcov.info | grep -v ",0$" | wc -l || echo "0")

echo ""
echo "   📊 Coverage summary:"
echo "   Non-fork: $nofork_hit/$nofork_lines lines"
echo "   Fork:     $fork_hit/$fork_lines lines"
echo "   Merged:   $merged_hit/$merged_lines lines"

# Cleanup
rm -f /tmp/foundry_nofork_lcov.info /tmp/foundry_fork_lcov.info

echo ""
echo "   ✅ Merged foundry coverage written to coverage/foundry_lcov.info"
echo ""
