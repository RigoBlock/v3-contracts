// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

/// @notice Supported Applications.
/// @dev Preserve order when adding new applications, last one is the counter.
enum Applications {
    GRG_STAKING,
    UNIV4_LIQUIDITY,
    GMX_V2_POSITIONS,
    HYPERLIQUID,
    LIGHTER_PERPS,
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

/// @notice Packed Lighter in-flight accounting. Unlike Hyperliquid there is no L1-block precompile:
///  pending requests are valued exactly by the transaction-status read (status 0), while a settled
///  request (status != 0) has an async EVM-side leg (refund/delivery) whose landing is not
///  observable on-chain — the pool's USDC wallet balance is not a reliable signal, since mints,
///  donations and plain transfers move it indistinguishably from the leg itself. Settled requests
///  therefore lock NAV-dependent flows until the owner attests the leg landed via
///  LighterLib.clearAction (ALighter.syncTransfer), verified off-chain per Lighter's docs.
///  Transfers are one-at-a-time: recordAction requires the previous request to be settled.
struct LighterData {
    int128 inFlightAmount;
    uint64 lastReqId;
}

/// @notice Lighter perps storage: in-flight accounting plus the tracked-market registry.
/// @dev `marketIndex` stores the 1-based position in `trackedMarkets` (0 = not tracked).
/// @dev Single-slot umbrella for all Lighter state: future extensions (e.g. tracked spot tokens)
///  append new fields/mappings here without touching existing layout, following the HyperliquidSlot
///  pattern.
struct LighterSlot {
    LighterData data;
    uint16[] trackedMarkets;
    mapping(uint16 marketId => uint256 index) marketIndex;
}

/// @notice Pool-storage view of the Lighter slot, returned by EApps.getLighterTrackedMarkets as a
///  client/test view. Since devnet 1.2.0 no per-market constants are stored: position values use
///  the on-chain quoteMultiplier. See docs/lighter/INTEGRATION.md.
struct LighterViewData {
    uint16[] marketIds;
    int128 inFlightAmount;
    uint64 lastReqId;
}
