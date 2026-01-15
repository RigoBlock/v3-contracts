#!/bin/bash
set -e

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "                    COVERAGE ANALYSIS REPORT"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Check if coverage files exist
if [ ! -f "coverage/lcov.info" ]; then
    echo "❌ Hardhat coverage file not found!"
    exit 1
fi

if [ ! -f "coverage/foundry_lcov.info" ]; then
    echo "❌ Foundry coverage file not found!"  
    exit 1
fi

echo "📊 Individual Coverage Reports:"
echo ""

# Analyze Hardhat coverage
echo "🔨 HARDHAT COVERAGE:"
hardhat_total_lines=$(grep -c "^DA:" coverage/lcov.info || echo "0")
hardhat_hit_lines=$(grep "^DA:" coverage/lcov.info | grep -v ",0$" | wc -l || echo "0")
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

# Check if Foundry coverage is suspiciously low (possible fork test failures)
if [ "$foundry_total_lines" -gt 0 ]; then
    foundry_pct_int=$(echo "$foundry_pct" | awk '{print int($1)}')
    if [ "$foundry_pct_int" -lt 20 ]; then
        echo ""
        echo "⚠️  WARNING: Foundry coverage is unusually low ($foundry_pct%)"
        echo "   This may indicate that fork tests failed due to RPC issues."
        echo "   Check that RPC URLs are properly configured and accessible."
        echo "   Fork tests: ENavViewFork.t.sol, TransferEscrow.t.sol, PoolDonate.t.sol"
        echo ""
    fi
fi

echo ""
echo "📋 FILES WITH MISSING COVERAGE (uncovered by BOTH Hardhat and Foundry):"
echo ""

# Find files with missing coverage from both tools
temp_hardhat="/tmp/hardhat_missing.txt"
temp_foundry="/tmp/foundry_missing.txt"
temp_common="/tmp/common_missing.txt"

# Extract missing lines from Hardhat coverage (normalize paths to relative)
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
echo "📤 Uploading both Hardhat and Foundry coverage files to Codecov"
echo "   Codecov will intelligently merge them for final reporting"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo ""