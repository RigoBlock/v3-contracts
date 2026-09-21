#!/bin/bash
set -euo pipefail

# Foundry coverage — single invocation over ALL tests (unit + fork together).
#
# Why one invocation: measured on forge 1.8.1, a single run covers a SUPERSET of
# the lines the previous 3-run split (library / non-fork / fork + lcov merge)
# covered, and the split required per-file include/exclude lists and contract-name
# conventions that rotted with every new test file. Forge coverage has known
# hit-count attribution quirks for libraries inlined into contracts deployed by
# several suites (e.g. GmxAdapterLib recorded 69 hits instead of 81): only the
# COUNT is affected, never whether the line counts as covered — and Codecov's
# line view only needs hit > 0. Refs:
#   - foundry-rs/foundry#7054 / #2826 (library coverage attribution)
#   - foundry-rs/foundry#4952 (invariant tests pathologically slow under coverage)
#   - foundry-rs/foundry#6442 (fork + coverage flakiness)
#
# forge coverage EXITS 0 EVEN WHEN TESTS FAIL (RPC rate limits, archive timeouts).
# Without detection, an all-zero fork coverage report gets uploaded to Codecov
# and lines that fork tests cover show as uncovered (see
# docs/COVERAGE_TROUBLESHOOTING.md). The grep below turns silent data corruption
# into a loud CI failure instead.
#
# Stable exclusions only — no per-file or per-contract lists to maintain:
#   --no-match-coverage   report scope: mocks/test/tokens/utils sources are never
#                         reported (unchanged since the first coverage setup)
#   test/debug/**         manual debug scripts, not coverage targets
#   PolygonFork / A0xRouterUnichainFork  local-only networks, not covered in CI
#                         (matching test:foundry, which also skips them)
#   DelegationLibFuzz / ECrosschainFuzzTest  invariant suites are excluded for CI
#                         time (#4952); DelegationLibFuzz shares its file with
#                         DelegationLib unit tests so it cannot be excluded by path

mkdir -p coverage
rm -f lcov.info

LOG=/tmp/forge_coverage.log

forge coverage \
  --no-match-coverage "mocks/|examples/|test/|tokens/|utils/" \
  --no-match-path 'test/{debug/**,extensions/PolygonFork.t.sol,extensions/A0xRouterUnichainFork.t.sol}' \
  --no-match-contract 'DelegationLibFuzz|ECrosschainFuzzTest' \
  --report lcov 2>&1 | tee "$LOG"

# forge coverage exits 0 even with failing tests — refuse to upload bad coverage.
if grep -Eq "([1-9][0-9]* failed|Failing tests)" "$LOG"; then
  echo "" >&2
  echo "❌ ERROR: forge coverage had failing tests (usually RPC/fork issues)." >&2
  echo "   Refusing to write a bad coverage report. Retry the CI job." >&2
  echo "   See docs/COVERAGE_TROUBLESHOOTING.md" >&2
  exit 1
fi

mv lcov.info coverage/foundry_lcov.info

total=$(grep -c "^DA:" coverage/foundry_lcov.info || echo 0)
hit=$(grep "^DA:" coverage/foundry_lcov.info | grep -v ",0$" | wc -l || echo 0)
echo ""
echo "📊 Foundry coverage: $hit/$total lines covered"
echo "   ✅ coverage/foundry_lcov.info written"
