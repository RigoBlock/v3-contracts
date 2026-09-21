// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

/// @title ForkBlocks - Fork block numbers for testing
/// @notice Isolated fork block numbers to minimize cache invalidation
/// @dev This file is hashed in CI cache key. Only modify when fork blocks need updating.
library ForkBlocks {
    /// @notice Mainnet block number for fork tests
    /// @dev Must be after the TEST_POOL implementation upgrade that routes `donate()` through
    ///      ECrosschain (block 25,530,528). Update only when the cached fork state needs to change.
    uint256 internal constant MAINNET_BLOCK = 25_600_000;

    /// @notice Base chain block number for fork tests
    uint256 internal constant BASE_BLOCK = 39521323;

    /// @notice Polygon chain block number for fork tests
    uint256 internal constant POLYGON_BLOCK = 81_000_000;

    /// @notice Unichain block number for fork tests (just before TX1 at block 41291308, and also TX2/TX3)
    uint256 internal constant UNICHAIN_BLOCK = 41_291_300;

    /// @notice Arbitrum One block number for fork tests (GMX v2 adapter tests).
    /// @dev Any recent block works: every GMX fork test creates its own fixture pool and
    ///      positions at this block (no test asserts on live third-party state). The value is
    ///      pinned only for CI fork-cache stability and archive availability on the CI RPC.
    ///      Update freely when the cached fork state needs to change; the fallback fork tests
    ///      in AGmxV2ForkTest fail loudly with a "bump ForkBlocks.ARB_BLOCK" hint when a GMX
    ///      synthetic token listed after this block is added to the fallback table.
    uint256 internal constant ARB_BLOCK = 503_353_273;

    /// @notice HyperEVM block number for fork tests.
    /// @dev HyperEVM mainnet block ~41M (July 2026). Update only when the cached fork state needs to change.
    uint256 internal constant HYPEREVM_BLOCK = 41_000_000;
}
