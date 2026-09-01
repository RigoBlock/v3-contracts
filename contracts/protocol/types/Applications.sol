// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

/// @notice Supported Applications.
/// @dev Preserve order when adding new applications, last one is the counter.
enum Applications {
    GRG_STAKING,
    UNIV4_LIQUIDITY,
    GMX_V2_POSITIONS,
    HYPERLIQUID,
    // append new applications here, up to a total of 255 as a theoretical maximum
    COUNT
}

struct TokenIdsSlot {
    uint256[] tokenIds;
    mapping(uint256 tokenId => uint256 index) positions;
}

/// @notice Packed Hyperliquid in-flight accounting.
/// @dev `lastActionCompositeBlock` stores `(l1BlockNumber << 128) | block.number` so that the
///  in-flight window aligns with HyperCore state updates rather than EVM block production.
/// @dev `lastActionTimestamp` records when any Hyperliquid action was last recorded.
struct HyperliquidData {
    uint256 lastActionCompositeBlock;
    int128 inFlightAmount;
    uint64 pendingSpotSend;
    uint48 lastActionTimestamp;
}
