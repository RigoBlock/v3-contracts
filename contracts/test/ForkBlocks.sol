// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

/// @title ForkBlocks - Fork block numbers for testing
/// @notice Isolated fork block numbers to minimize cache invalidation
/// @dev This file is hashed in CI cache key. Only modify when fork blocks need updating.
library ForkBlocks {
    /// @notice Mainnet block number after oracle deployment (22,425,175)
    /// @dev Use this for tests requiring oracle price feeds
    uint256 internal constant MAINNET_BLOCK = 24_000_000;

    /// @notice Base chain block number for fork tests
    uint256 internal constant BASE_BLOCK = 39521323;

    /// @notice Polygon chain block number for fork tests
    uint256 internal constant POLYGON_BLOCK = 81_000_000;

    /// @notice Unichain block number for fork tests (just before TX1 at block 41291308, and also TX2/TX3)
    uint256 internal constant UNICHAIN_BLOCK = 41_291_300;

    /// @notice Arbitrum One block number for fork tests (GMX v2 adapter tests).
    /// @dev Block ~430M corresponds to approximately late January 2026.
    uint256 internal constant ARB_BLOCK = 430_000_000;
}
