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
///  the in-flight window aligns with LighterEVM block production, as READ_CORE reads are pinned to
///  the parent Core block snapshot and never reflect same-block Core writes. `lastReqId` is the
///  Core request of the latest deposit/withdrawal (0 = none/orders only): the transaction-status
///  read drives the exact in-flight adjustment while it is pending. Only the latest reqId is
///  tracked — batching a deposit and a withdrawal in one block loses per-request granularity.
struct LighterData {
    uint48 lastActionBlock;
    int128 inFlightAmount;
    uint48 lastActionTimestamp;
    uint64 lastReqId;
}

/// @notice Decimal scaling of a tracked Lighter perp market. Values are copied from the
///  LighterConstants.marketDecimals release-time table at track time (the READ_CORE market info
///  does not expose them): `position * markPrice / 10^(sizeDecimals + priceDecimals)` yields
///  quote whole units; the NAV formula is documented in LighterLib._positionValueUsdc.
struct TrackedMarket {
    uint8 sizeDecimals;
    uint8 priceDecimals;
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
    mapping(uint16 marketId => TrackedMarket market) markets;
}

/// @notice Pool-storage view of the Lighter slot, returned by EApps.getLighterTrackedMarkets as a
///  client/test view. The decimal scales are release-time protocol constants copied from
///  LighterConstants.marketDecimals at track time (never caller input). See
///  docs/lighter/INTEGRATION.md.
struct LighterViewData {
    uint16[] marketIds;
    uint8[] sizeDecimals;
    uint8[] priceDecimals;
    int128 inFlightAmount;
    uint48 lastActionTimestamp;
    uint64 lastReqId;
}
