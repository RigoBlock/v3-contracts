#!/bin/bash
set -e

echo "🔍 Rigoblock v3-contracts Security Analysis"
echo "==========================================="
echo ""

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if slither is installed
if ! command -v slither &> /dev/null; then
    echo -e "${RED}❌ Slither not installed${NC}"
    echo ""
    echo "Install with:"
    echo "  pip3 install --user slither-analyzer"
    echo ""
    echo "Then add to PATH:"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
    exit 1
fi

echo -e "${GREEN}✓${NC} Slither version: $(slither --version)"
echo ""

# Default target
TARGET="${1:-contracts/protocol/}"
SEVERITY="${2:-all}"

echo -e "${BLUE}Target:${NC} $TARGET"
echo -e "${BLUE}Severity filter:${NC} $SEVERITY"
echo ""

# Build severity flags
SEVERITY_FLAGS=""
if [ "$SEVERITY" = "high" ]; then
    SEVERITY_FLAGS="--exclude-medium --exclude-low --exclude-informational"
elif [ "$SEVERITY" = "medium" ]; then
    SEVERITY_FLAGS="--exclude-low --exclude-informational"
elif [ "$SEVERITY" = "critical" ]; then
    SEVERITY_FLAGS="--exclude-high --exclude-medium --exclude-low --exclude-informational"
fi

echo "Running Slither analysis..."
echo ""

# Run slither
slither "$TARGET" \
    --filter-paths "contracts/test|contracts/mocks|lib/" \
    --exclude naming-convention,solc-version \
    $SEVERITY_FLAGS \
    --json slither-results.json \
    || true

echo ""
echo "==========================================="
echo -e "${GREEN}✓${NC} Analysis complete!"
echo ""
echo "Results saved to: slither-results.json"
echo ""
echo "📊 To generate markdown report:"
echo "   slither $TARGET --checklist"
echo ""
echo "🔍 To focus on specific severity:"
echo "   $0 $TARGET high        # High + Critical only"
echo "   $0 $TARGET medium      # Medium + High + Critical"
echo "   $0 $TARGET critical    # Critical only"
echo ""
echo "📝 To analyze specific contract:"
echo "   $0 contracts/protocol/SmartPool.sol"
echo ""
