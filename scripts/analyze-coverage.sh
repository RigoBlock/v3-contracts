#!/bin/bash
set -euo pipefail

# Coverage ANALYZER — read-only. Runs no coverage, modifies no reports.
#
# Inputs (all produced by the native coverage commands):
#   coverage/lcov.info         Hardhat 3 raw report (`hardhat test mocha --coverage`)
#   coverage/foundry_lcov.info Foundry raw report (coverage:foundry, tee'd to the log below)
#   /tmp/forge_coverage.log    stdout of `forge coverage` (tee'd by the package.json script)
#
# Outputs: analysis on stdout only. No report files are written, filtered, or
# amended — Codecov receives both lcov files exactly as the tools produced them
# (we are deliberately testing Codecov's own union aggregation after upgrades).
#
# Guard rails (exit 1): forge coverage exits 0 even when tests fail or fork
# suites silently never run, which used to upload garbage reports to Codecov
# (see docs/COVERAGE_TROUBLESHOOTING.md). See docs/COVERAGE_TROUBLESHOOTING.md.

LOG=/tmp/forge_coverage.log

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "                    COVERAGE ANALYSIS REPORT"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Check if coverage files exist
hardhat_lcov_available=true
if [ ! -f "coverage/lcov.info" ]; then
    echo "⚠️  Hardhat coverage file not found (expected from Hardhat 3's built-in coverage) — analyzing Foundry coverage only"
    hardhat_lcov_available=false
fi

if [ ! -f "coverage/foundry_lcov.info" ]; then
    echo "❌ Foundry coverage file not found!"
    exit 1
fi

if [ ! -f "$LOG" ]; then
    echo "❌ Forge coverage log not found at $LOG (coverage:foundry must tee its output there)"
    exit 1
fi

echo "📊 Individual Coverage Reports:"
echo ""

# Analyze Hardhat coverage
echo "🔨 HARDHAT COVERAGE:"
if [ "$hardhat_lcov_available" = true ]; then
    hardhat_total_lines=$(grep -c "^DA:" coverage/lcov.info || echo "0")
    hardhat_hit_lines=$(grep "^DA:" coverage/lcov.info | grep -v ",0$" | wc -l || echo "0")
else
    hardhat_total_lines=0
    hardhat_hit_lines=0
fi
if [ "$hardhat_total_lines" -gt 0 ]; then
    hardhat_pct=$(awk "BEGIN {printf \"%.2f\", ($hardhat_hit_lines/$hardhat_total_lines)*100}")
else
    hardhat_pct="0.00"
fi
echo "   Lines: $hardhat_hit_lines/$hardhat_total_lines ($hardhat_pct%)"

echo ""
echo "⚡ FOUNDRY COVERAGE:"
foundry_total_lines=$(grep -c "^DA:" coverage/foundry_lcov.info || echo "0")
foundry_hit_lines=$(grep "^DA:" coverage/foundry_lcov.info | grep -v ",0$" | wc -l || echo "0")
if [ "$foundry_total_lines" -gt 0 ]; then
    foundry_pct=$(awk "BEGIN {printf \"%.2f\", ($foundry_hit_lines/$foundry_total_lines)*100}")
else
    foundry_pct="0.00"
fi
echo "   Lines: $foundry_hit_lines/$foundry_total_lines ($foundry_pct%)"

# ─── Guard 1: forge coverage exits 0 even with failing tests (RPC rate limits,
# archive timeouts). Without detection, an all-zero fork coverage report gets
# uploaded to Codecov and lines that fork tests cover show as uncovered.
if grep -Eq "([1-9][0-9]* failed|Failing tests)" "$LOG"; then
    echo "" >&2
    echo "❌ ERROR: forge coverage had failing tests (usually RPC/fork issues)." >&2
    echo "   Refusing to upload a bad coverage report. Retry the CI job." >&2
    echo "   See docs/COVERAGE_TROUBLESHOOTING.md" >&2
    exit 1
fi
echo "   ✅ no failing tests in forge coverage log"

# ─── Guard 2: sentinel fork suites. The failure grep above cannot catch fork
# suites that SILENTLY never ran (a future exclusion/path change, or a
# fork-creation error that forge reports but does not count as a test failure):
# unit tests still pass, coverage is still written, and it is garbage for every
# fork-only file.
if ! grep -Eq ":(AUniswapRouterForkTest|AUniswapRouterExecuteForkTest|AUniswapRouterModifyLiquiditiesForkTest|AGmxV2ForkTest|A0xRouterForkTest)\b" "$LOG"; then
    echo "" >&2
    echo "❌ ERROR: no known fork suite (AUniswapRouter/AGmxV2/A0xRouter) appears in the forge output." >&2
    echo "   Fork tests did not actually run — coverage would be silently incomplete." >&2
    echo "   Check foundry.toml [profile.coverage] exclusions and RPC availability; retry the CI job." >&2
    echo "   See docs/COVERAGE_TROUBLESHOOTING.md" >&2
    exit 1
fi
echo "   ✅ sentinel fork suites ran"

# ─── Guard 3: deployCode instrumentation canary. The coverage:foundry prebuild
# (FOUNDRY_PROFILE=coverage forge build) must produce optimizer-off artifacts
# byte-identical to forge coverage's internal build, or every deployCode-
# deployed contract (AUniswapRouter.sol via its 0.8.37 isolated job, fixtures,
# mocks) records zero hits. A zero total/hit DA count on either adapter file
# means that mechanism silently broke (e.g. a future forge version changes the
# coverage build) and the report would re-introduce rogue uncovered lines.
for adapter in \
    contracts/protocol/extensions/adapters/AUniswapRouter.sol \
    contracts/protocol/extensions/adapters/AUniswapDecoder.sol; do
    da=$(awk -v sf="$adapter" '/^SF:/{insf=($0=="SF:"sf)} insf && /^DA:/{tot++; if ($0 !~ /,0$/) hit++} insf && /^end_of_record/{print hit+0 "/" tot+0; exit}' coverage/foundry_lcov.info)
    total_part="${da##*/}"
    hit_part="${da%%/*}"
    if [ -z "$da" ] || [ "${total_part:-0}" -eq 0 ] || [ "${hit_part:-0}" -eq 0 ]; then
        echo "" >&2
        echo "❌ ERROR: $adapter has $da hit/total DA lines in the Foundry report." >&2
        echo "   The coverage-profile prebuild is not taking effect (see foundry.toml" >&2
        echo "   [profile.coverage] and docs/COVERAGE_TROUBLESHOOTING.md)." >&2
        echo "   Refusing to upload a report with rogue uncovered lines." >&2
        exit 1
    fi
    echo "   ✅ $adapter instrumented: $da DA lines hit"
done

# ─── Guard 4: fork-coverage floor. Catches the other silent-degradation mode:
# fork suites dropping out via a future exclusion/path change with every
# remaining test still "passing" — e.g. AGmxV2Fork excluded would zero out all
# GMX files yet produce a clean-looking report. Historical bad run (RPC outage
# era): 462 hit lines (16.9% of the report); a normal full run is ~1800+.
if [ "$foundry_hit_lines" -lt 1000 ]; then
    echo "" >&2
    echo "❌ Foundry report has only $foundry_hit_lines hit lines — fork suites did not contribute." >&2
    echo "   Refusing to upload coverage. Check exclusions in foundry.toml" >&2
    echo "   [profile.coverage] and retry the CI job. See docs/COVERAGE_TROUBLESHOOTING.md" >&2
    exit 1
fi
echo "   ✅ foundry fork-coverage floor: $foundry_hit_lines hit lines (floor 1000)"

echo ""
echo "📤 CODECOV UPLOAD (raw reports, unmodified):"
if [ "$hardhat_lcov_available" = true ]; then
    echo "   - Hardhat: ./coverage/lcov.info"
fi
echo "   - Foundry: ./coverage/foundry_lcov.info"
echo "   Codecov union-merges the two uploads per line; no client-side filtering is applied."

echo ""
echo "📋 FILES WITH MISSING COVERAGE (uncovered by BOTH Hardhat and Foundry):"
echo ""

# Find lines with missing coverage from both tools (temp files in a private
# mktemp dir, removed on exit — the script writes no reports).
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
temp_hardhat="$tmpdir/hardhat_missing.txt"
temp_foundry="$tmpdir/foundry_missing.txt"
temp_common="$tmpdir/common_missing.txt"

# Extract missing lines from Hardhat coverage (normalize paths to relative)
if [ "$hardhat_lcov_available" = true ]; then
    awk '
/^SF:/ {
    current_file = substr($0, 4)
    # Normalize absolute paths to relative
    gsub(/.*\/contracts\//, "contracts/", current_file)
}
/^DA:.*,0$/ {
    line_num = substr($0, 4)
    gsub(/,0$/, "", line_num)
    print current_file ":" line_num
}
' coverage/lcov.info > "$temp_hardhat"
fi

# Extract missing lines from Foundry coverage (deduplicate and only count truly uncovered)
awk '
/^SF:/ { current_file = substr($0, 4) }
/^DA:/ {
    split($0, parts, ",")
    line_num = substr(parts[1], 4)
    hits = parts[2]
    # Track maximum hits for each line (deduplication)
    key = current_file ":" line_num
    if (!(key in max_hits) || hits > max_hits[key]) {
        max_hits[key] = hits
    }
}
/^end_of_record/ {
    # Output only lines with 0 hits after deduplication
    for (key in max_hits) {
        if (max_hits[key] == 0) {
            print key
        }
    }
    delete max_hits
}
' coverage/foundry_lcov.info > "$temp_foundry"

# Without Hardhat coverage, every line Foundry misses is effectively uncovered,
# so treat all Foundry-missing lines as the intersection.
if [ "$hardhat_lcov_available" != true ]; then
    cp "$temp_foundry" "$temp_hardhat"
fi

# Find lines that are missing in BOTH reports (intersection)
comm -12 <(sort "$temp_hardhat") <(sort "$temp_foundry") > "$temp_common"

# Group by file and show lines uncovered by both tools, filter for protocol files
cat "$temp_common" | grep -E "(protocol/|staking/|governance/|rigoToken/)" | awk -F: '
{
    file = $1
    line = $2
    if (file != last_file) {
        if (last_file != "") {
            # Print accumulated lines for previous file
            for (i = 1; i <= count; i++) {
                if (i == 1) printf "   Missing lines: " lines[i]
                else if (i <= 15) printf ", " lines[i]
                else if (i == 16) printf " ... (+" (count-15) " more)"
                else break
            }
            if (count > 0) print ""
        }
        print "📄 " file ":"
        last_file = file
        count = 0
    }
    count++
    lines[count] = line
}
END {
    # Print final file lines
    if (count > 0) {
        for (i = 1; i <= count; i++) {
            if (i == 1) printf "   Missing lines: " lines[i]
            else if (i <= 15) printf ", " lines[i]
            else if (i == 16) printf " ... (+" (count-15) " more)"
            else break
        }
        print ""
    }
}' | head -50

echo ""
echo "════════════════════════════════════════════════════════════════"
echo ""
