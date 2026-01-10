#!/bin/bash
# Foundry Cache Management for CI
#
# This script explains the caching strategy to preserve RPC fork data
# while ensuring fresh coverage reports.
#
# CACHE STRATEGY:
# 
# 1. FORK CACHE (persistent, expensive to rebuild):
#    Location: ~/.foundry/cache/rpc/
#    Contains: Blockchain state snapshots from RPC endpoints
#    Cache Key: Only changes when workflow changes (very stable)
#    Purpose: Avoid expensive RPC calls for fork tests
#
# 2. BUILD CACHE (invalidated on contract/test changes):
#    Location: cache_forge/, out/
#    Contains: Compiled contracts, compilation metadata
#    Cache Key: Based on contract and test file hashes
#    Purpose: Speed up compilation when code doesn't change
#
# 3. NODE MODULES CACHE (persistent):
#    Location: node_modules/
#    Contains: JavaScript dependencies  
#    Cache Key: Based on yarn.lock
#    Purpose: Speed up dependency installation

echo "🔍 Checking cache sizes..."

# Check fork cache size (if exists)
if [ -d "$HOME/.foundry/cache" ]; then
    FORK_CACHE_SIZE=$(du -sh "$HOME/.foundry/cache" 2>/dev/null | cut -f1)
    echo "📁 Fork cache size: $FORK_CACHE_SIZE"
else
    echo "📁 No fork cache found"
fi

# Check project cache size
if [ -d "cache_forge" ]; then
    BUILD_CACHE_SIZE=$(du -sh cache_forge 2>/dev/null | cut -f1)
    echo "🔨 Build cache size: $BUILD_CACHE_SIZE"
fi

if [ -d "out" ]; then
    OUT_CACHE_SIZE=$(du -sh out 2>/dev/null | cut -f1)
    echo "📦 Output cache size: $OUT_CACHE_SIZE"
fi

echo "✅ Cache strategy preserves expensive fork data while ensuring fresh coverage"