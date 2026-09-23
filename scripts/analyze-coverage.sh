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
# The Hardhat report contains zero-hit entries for every file Hardhat never
# executes (Hardhat compiles every contract under contracts/ and reports all
# compiled sources — GmxLib, GmxAdapterLib, EGmxCallback, GmxCallbackLib,
# GmxClaimableHelpers, CrosschainLib, Escrow, HyperliquidLib) AND zero-hit
# lines inside files it does execute, on continuation lines of multi-line
# statements that Foundry instruments only at the statement anchor. Example
# (AGmxV2.sol): Foundry reports hits on L84/86/90 and nothing on L85/87/89;
# Hardhat reports 0 on L85/87/89. Those zeros are instrumentation artifacts
# of executed statements, but Codecov counts them as patch misses (observed
# on PR #964: 6 false misses on changed GMX lines).
#
# Codecov union-merges uploads per line and "does not override report data"
# (docs.codecov.com/docs/merging-reports), so filtering cannot hide Foundry
# hits in the merged view. The filter drops, from the Hardhat upload:
#   1. SF blocks whose total hits are 0 (Foundry-only files — keeps per-flag
#      views consistent: each file is owned by the suite that executes it).
#   2. Individual DA:line,0 entries for files Foundry covers, when Foundry
#      does not instrument that line at all. A line Foundry considers
#      non-executable cannot be a genuine miss of executable code; if it
#      were genuinely uncovered, Foundry would list it with 0 hits and the
#      union would still report 0.
if [ "$hardhat_lcov_available" = true ]; then
    awk '
    NR == FNR {
        # Pass 1: index the Foundry report — covered files and instrumented lines.
        if ($0 ~ /^SF:/) {
            sf = substr($0, 4)
            gsub(/.*\/contracts\//, "contracts/", sf)
        } else if ($0 ~ /^DA:/) {
            split($0, p, ",")
            sub(/^DA:/, "", p[1])
            fline[sf ":" p[1]] = 1
            if (p[2] + 0 > 0) fhitfile[sf] = 1
        }
        next
    }
    function emitblock() {
        if (inblock && lh > 0) printf "%s%sLF:%d\nLH:%d\nend_of_record\n", buf, das, lf, lh
        inblock = 0; buf = ""; das = ""; lf = 0; lh = 0
    }
    /^SF:/              { emitblock(); inblock = 1
                          sf = substr($0, 4); gsub(/.*\/contracts\//, "contracts/", sf)
                          buf = $0 ORS; next }
    inblock && /^DA:/   {
        split($0, p, ","); sub(/^DA:/, "", p[1])
        if (fhitfile[sf] && p[2] + 0 == 0 && !((sf ":" p[1]) in fline)) next
        das = das $0 ORS; lf++
        if (p[2] + 0 > 0) lh++
        next
    }
    inblock && /^LF:/   { next }  # recomputed from the filtered DA set
    inblock && /^LH:/   { next }
    inblock             { buf = buf $0 ORS }
    inblock && /^end_of_record/ { emitblock(); next }
    END                 { emitblock() }
    ' coverage/foundry_lcov.info coverage/lcov.info > coverage/lcov-upload.info

    raw_files=$(grep -c "^SF:" coverage/lcov.info || echo "0")
    kept_files=$(grep -c "^SF:" coverage/lcov-upload.info || echo "0")
    echo ""
    echo "📤 CODECOV UPLOAD PREPARATION:"
    echo "   Hardhat report: $raw_files files → $kept_files files after removing zero-hit blocks"
    echo "   (removed files are covered exclusively by Foundry; uploaded as Foundry-owned)"
fi

# ─── Foundry fork-coverage floor ─────────────────────────────────────────────
#
# The failure grep in foundry-coverage.sh already rejects reports with failed
# tests. This floor catches the other silent-degradation mode: fork suites
# dropping out via a future exclusion/path change with every remaining test
# still "passing" — e.g. AGmxV2Fork excluded would zero out all GMX files yet
# produce a clean-looking report. Historical bad run (RPC outage era): 462 hit
# lines (16.9% of the report); a normal full run is ~1800+.
if [ "$foundry_hit_lines" -lt 1000 ]; then
    echo "" >&2
    echo "❌ Foundry report has only $foundry_hit_lines hit lines — fork suites did not contribute." >&2
    echo "   Refusing to upload coverage. Check exclusions in scripts/foundry-coverage.sh" >&2
    echo "   and retry the CI job. See docs/COVERAGE_TROUBLESHOOTING.md" >&2
    exit 1
fi
echo "   ✅ foundry fork-coverage floor: $foundry_hit_lines hit lines (floor 1000)"

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