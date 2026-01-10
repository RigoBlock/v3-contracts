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

# Show sample of covered files
echo "📋 Sample covered files:"
grep '^SF:' coverage/combined_lcov.info | head -5

# Validate LCOV format
if ! head -5 coverage/combined_lcov.info | grep -q "^SF:"; then
    echo "❌ Error: Invalid LCOV format detected!"
    exit 1
fi

echo "✅ Coverage validation completed successfully"