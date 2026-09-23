#!/bin/bash
set -e

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

# ─── Codecov upload preparation ──────────────────────────────────────────────
#
# The Hardhat report contains SF blocks with zero hits for files that are ONLY
# ever executed by Foundry fork tests (Hardhat compiles every contract under
# contracts/ but never executes GMX/Across/Hyperliquid code). Uploading those
# zero blocks alongside the Foundry report means two flags claim the same file
# with contradictory data, and any Foundry upload hiccup leaves the zeros as
# the only data — fork-covered lines then show as "missed" on the PR view.
#
# Fix: upload a filtered Hardhat report from which zero-hit files are removed.
# A file absent from a report carries no data (Codecov union-merges per line);
# after filtering, each file is owned by exactly the suite that executes it.
if [ "$hardhat_lcov_available" = true ]; then
    awk '
    function emitblock() {
        if (inblock && lh > 0) printf "%s", buf
        inblock = 0; buf = ""; lh = 0
    }
    /^SF:/          { emitblock(); inblock = 1; buf = $0 ORS; next }
    inblock         { buf = buf $0 ORS }
    inblock && /^LH:/ { lh = substr($0, 4) + 0 }
    inblock && /^end_of_record/ { emitblock() }
    END             { emitblock() }
    ' coverage/lcov.info > coverage/lcov-upload.info

    raw_files=$(grep -c "^SF:" coverage/lcov.info || echo "0")
    kept_files=$(grep -c "^SF:" coverage/lcov-upload.info || echo "0")
    echo ""
    echo "📤 CODECOV UPLOAD PREPARATION:"
    echo "   Hardhat report: $raw_files files → $kept_files files after removing zero-hit blocks"
    echo "   (zero-hit files are covered exclusively by Foundry; uploaded as Foundry-owned)"
fi

# ─── Fork-suite sentinel assertion ───────────────────────────────────────────
#
# Proves the Foundry report actually contains fork-test coverage: these files
# are executed ONLY by Foundry fork suites, so a report without hits for them
# means fork coverage silently did not make it into the upload. Fail loudly
# instead of letting Codecov publish a hardhat-zeros-only view of these files.
SENTINEL_FILES="contracts/protocol/libraries/GmxLib.sol
contracts/protocol/libraries/GmxAdapterLib.sol
contracts/protocol/extensions/EGmxCallback.sol
contracts/protocol/libraries/GmxCallbackLib.sol
contracts/protocol/libraries/CrosschainLib.sol
contracts/protocol/libraries/HyperliquidLib.sol"

sentinel_failed=0
for f in $SENTINEL_FILES; do
    hits=$(awk -v target="$f" '
        $0 == "SF:" target { inblock = 1; next }
        inblock && /^end_of_record/ { inblock = 0 }
        inblock && /^DA:/ { split($0, p, ","); total += p[2] }
        END { print total + 0 }
    ' coverage/foundry_lcov.info)
    if [ "$hits" -eq 0 ]; then
        echo "❌ SENTINEL: $f has 0 Foundry hits — fork suites did not cover it" >&2
        sentinel_failed=1
    else
        echo "   ✅ sentinel: $f ($hits foundry hits)"
    fi
done
if [ "$sentinel_failed" -ne 0 ]; then
    echo "" >&2
    echo "❌ Refusing to upload coverage: Foundry report is missing fork coverage." >&2
    echo "   Retry the CI job (RPC pressure) — see docs/COVERAGE_TROUBLESHOOTING.md" >&2
    exit 1
fi

echo ""
echo "📋 FILES WITH MISSING COVERAGE (uncovered by BOTH Hardhat and Foundry):"
echo ""

# Find files with missing coverage from both tools
temp_hardhat="/tmp/hardhat_missing.txt"
temp_foundry="/tmp/foundry_missing.txt"
temp_common="/tmp/common_missing.txt"

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

rm -f "$temp_hardhat" "$temp_foundry" "$temp_common"

echo ""
echo "📤 Uploading coverage files to Codecov:"
if [ "$hardhat_lcov_available" = true ]; then
    echo "   - Hardhat: ./coverage/lcov-upload.info (zero-hit files removed)"
else
    echo "   - Hardhat: (not available)"
fi
echo "   - Foundry: ./coverage/foundry_lcov.info"
echo "   Codecov union-merges per line; each file is owned by one suite only"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo ""