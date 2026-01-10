#!/bin/bash
set -e

if [ ! -f "coverage/combined_lcov.info" ]; then
    echo "❌ Error: Combined coverage file not found!"
    exit 1
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "                    COMBINED COVERAGE REPORT"
echo "         (Hardhat + Foundry - best coverage per file)"
echo "════════════════════════════════════════════════════════════════"
echo ""

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "                    COMBINED COVERAGE REPORT"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Parse LCOV file and display per-file coverage
awk '
/^SF:/ {
    file = substr($0, 4)
    lf = 0; lh = 0; brf = 0; brh = 0; fnf = 0; fnh = 0
}
/^LF:/ { lf = substr($0, 4) }
/^LH:/ { lh = substr($0, 4) }
/^BRF:/ { brf = substr($0, 5) }
/^BRH:/ { brh = substr($0, 5) }
/^FNF:/ { fnf = substr($0, 5) }
/^FNH:/ { fnh = substr($0, 5) }
/^end_of_record/ {
    if (file != "" && lf > 0) {
        stmt_pct = (lf > 0) ? (lh/lf)*100 : 100
        branch_pct = (brf > 0) ? (brh/brf)*100 : 100
        func_pct = (fnf > 0) ? (fnh/fnf)*100 : 100
        
        # Output for sorting: file|stmt|branch|func|lh|lf
        printf "%s|%.2f|%.2f|%.2f|%d|%d\n", file, stmt_pct, branch_pct, func_pct, lh, lf
        
        total_lf += lf; total_lh += lh
        total_brf += brf; total_brh += brh
        total_fnf += fnf; total_fnh += fnh
    }
}
END {
    # Print totals
    total_stmt = (total_lf > 0) ? (total_lh/total_lf)*100 : 100
    total_branch = (total_brf > 0) ? (total_brh/total_brf)*100 : 100
    total_func = (total_fnf > 0) ? (total_fnh/total_fnf)*100 : 100
    printf "ZZZTOTAL|%.2f|%.2f|%.2f|%d|%d\n", total_stmt, total_branch, total_func, total_lh, total_lf
}
' coverage/combined_lcov.info | sort | awk -F'|' '
BEGIN {
    printf "%-70s %8s %8s %8s %15s\n", "File", "Stmts", "Branch", "Funcs", "Lines"
    printf "%-70s %8s %8s %8s %15s\n", "----", "-----", "------", "-----", "-----"
}
$1 == "ZZZTOTAL" {
    printf "%-70s %8s %8s %8s %15s\n", "----", "-----", "------", "-----", "-----"
    printf "%-70s %7.2f%% %7.2f%% %7.2f%% %6d/%6d\n", "All files", $2, $3, $4, $5, $6
    next
}
{
    printf "%-70s %7.2f%% %7.2f%% %7.2f%% %6d/%6d\n", $1, $2, $3, $4, $5, $6
}
'

echo ""
echo "════════════════════════════════════════════════════════════════"
echo ""
