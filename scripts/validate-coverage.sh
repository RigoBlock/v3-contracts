#!/bin/bash
set -e

echo "=== Coverage Validation ==="

# Check if required files exist
if [ ! -f "coverage/combined_lcov.info" ]; then
    echo "❌ Error: Combined LCOV file not found!"
    exit 1
fi

if [ ! -f "coverage/lcov.info" ]; then
    echo "⚠️  Warning: Hardhat LCOV file not found!"
fi

if [ ! -f "coverage/foundry_lcov.info" ]; then
    echo "⚠️  Warning: Foundry LCOV file not found!"
fi

echo "✅ Combined coverage file exists"
echo "📊 File size: $(wc -c < coverage/combined_lcov.info) bytes"

# Count covered files
TOTAL_FILES=$(grep -c '^SF:' coverage/combined_lcov.info)
echo "📄 Number of files covered: $TOTAL_FILES"

# Check for CrosschainLib specifically
if grep -q "CrosschainLib.sol" coverage/combined_lcov.info; then
    echo "✅ CrosschainLib.sol found in coverage report"
    
    # Extract coverage stats for CrosschainLib
    echo "📈 CrosschainLib.sol coverage details:"
    sed -n '/SF:.*CrosschainLib\.sol$/,/end_of_record/p' coverage/combined_lcov.info | grep -E '^(LF|LH|FNF|FNH|BRF|BRH):' | while read line; do
        echo "   $line"
    done
else
    echo "❌ Error: CrosschainLib.sol not found in coverage report!"
    exit 1
fi

# Validate LCOV format
if ! head -5 coverage/combined_lcov.info | grep -q "^SF:"; then
    echo "❌ Error: Invalid LCOV format detected!"
    exit 1
fi

echo "✅ Coverage validation completed successfully"