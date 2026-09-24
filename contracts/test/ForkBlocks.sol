// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

/// @title ForkBlocks - Fork block numbers for testing
/// @notice Isolated fork block numbers to minimize cache invalidation
/// @dev This file is hashed in CI cache key. Only modify when fork blocks need updating.
/// @dev Hygiene rule: bump all blocks to recent values whenever a new branch is created
///      (at PR creation), so fork-state-dependent regressions surface early. See AGENTS.md.
library ForkBlocks {
    /// @notice Mainnet block number for fork tests (2026-09, ~26.0M)
    /// @dev Must be after the TEST_POOL implementation upgrade that routes `donate()` through
    ///      ECrosschain (block 25,530,528).
    uint256 internal constant MAINNET_BLOCK = 26_000_000;

    /// @notice Base chain block number for fork tests (2026-09, ~51.7M)
    uint256 internal constant BASE_BLOCK = 51_700_000;

    /// @notice Polygon chain block number for fork tests (2026-09, ~94.3M)
    uint256 internal constant POLYGON_BLOCK = 94_300_000;

    /// @notice Unichain block number for fork tests (2026-09, ~59.5M)
    /// @dev A0xRouterUnichainFork replays exact production calldata extracted at block
    ///      41_291_308, but resolves the 0x settler dynamically at the fork block, so this
    ///      pin follows routine bumps like every other chain.
    uint256 internal constant UNICHAIN_BLOCK = 59_500_000;

    /// @notice Arbitrum One block number for fork tests (GMX v2 adapter tests, 2026-09).
    /// @dev Any recent block works: every GMX fork test creates its own fixture pool and
    ///      positions at this block (no test asserts on live third-party state). The value is
    ///      pinned only for CI fork-cache stability and archive availability on the CI RPC.
    ///      Update freely when the cached fork state needs to change; the fallback fork tests
    ///      in AGmxV2ForkTest fail loudly with a "bump ForkBlocks.ARB_BLOCK" hint when a GMX
    ///      synthetic token listed after this block is added to the fallback table.
    /// @dev Pinned after the Universal Router 2.1.2 deployment (block 506_233_838, 2026-09-17)
    ///      so adapter fork tests can execute against the live 2.1.2 router.
    uint256 internal constant ARB_BLOCK = 508_400_000;

    /// @notice HyperEVM block number for fork tests (2026-09, ~46.7M)
    uint256 internal constant HYPEREVM_BLOCK = 46_700_000;
}
