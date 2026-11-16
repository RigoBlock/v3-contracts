// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

/// @title LighterTypes
/// @notice ABI layouts of the LighterCore state reads returned by the READ_CORE precompile.
/// @dev Defined here — next to the Lighter predeploy interfaces — rather than inside LighterLib so
///  that a future lighter-contracts git submodule can replace this single file as the source of
///  truth. Field names, order and widths mirror Lighter's "Reading Core from EVM" docs
///  (devnet 1.2.0 revision, 2026-11-11). Every read except tx status (0x0000) returns the documented
///  abi.encode(bool found, bytes data) envelope — found=false (with empty data, the read still
///  succeeding) means the account, asset, or market does not exist; a failed staticcall means a
///  malformed query. The structs below are the inner payload decoded from `data`; absence
///  semantics live in LighterLib. abi.decode of the 32-byte-word payloads tolerates wider declared
///  fields (trailing padding is dropped), so the uint48/uint56 widths are documentation, not consensus.
library LighterTypes {
    /// @notice READ_CORE 0x0001 (account info). `collateralBaseAmount` is the shared USDC margin
    ///  (Core USDC base units, 1e6 per USDC; excludes isolated margin). The envelope reports
    ///  found=false when the account does not exist in Core state.
    struct AccountInfo {
        uint8 accountType;
        uint48 accountIndex;
        uint48 masterAccountIndex;
        address l1Address;
        address evmAddress;
        int128 collateralBaseAmount;
    }

    /// @notice READ_CORE 0x0005 (market info). Devnet 1.2.0 layout: appends `quoteMultiplier`,
    ///  `fundingRatePrefixSum` and `lastFundingRoundTimestamp` to the 1.1.0 tuple.
    ///  `quoteMultiplier` converts `amount * price` to USDC base units (1e6 per USDC) —
    ///  value = amount * price * quoteMultiplier — replacing the release-time size/price
    ///  decimals table; it is 1..10000 for perpetuals and 0 for spot markets.
    ///  `fundingRatePrefixSum` is the running sum of funding rate times index price used for
    ///  pending-funding calculations (see LighterLib._pendingFunding). Prices remain on the
    ///  market-specific scales of `createOrder`. `baseAssetId`/`quoteAssetId` are spot-only:
    ///  they are 0 for perpetuals (verified live), as perps are USDC-settled by protocol design.
    ///  The envelope reports found=false when the market does not exist.
    struct MarketInfo {
        uint8 marketType;
        uint32 baseAssetId;
        uint32 quoteAssetId;
        uint32 takerFee;
        uint32 makerFee;
        uint64 minBaseAmount;
        uint64 minQuoteAmount;
        uint32 liquidationFee;
        uint64 indexPrice;
        uint64 markPrice;
        uint32 quoteMultiplier;
        int64 fundingRatePrefixSum;
        uint64 lastFundingRoundTimestamp;
    }

    /// @notice READ_CORE 0x0007 (position). Devnet 1.2.0 layout: appends `lastFundingRatePrefixSum`
    ///  (the market's fundingRatePrefixSum when funding was last settled for this position) to the
    ///  1.1.0 tuple. `size` is the signed position size on createOrder's amount scale.
    ///  `entryQuote` is the unsigned entry NOTIONAL VALUE in Core USDC base units (1e6 per USDC)
    ///  — not an entry price. `allocatedMargin` is in Core USDC base units (1e6 per USDC).
    struct Position {
        int64 size;
        uint56 entryQuote;
        uint16 initialMarginFraction;
        uint64 totalOrderCount;
        uint64 totalPositionTiedOrderCount;
        uint8 marginMode;
        int128 allocatedMargin;
        int64 lastFundingRatePrefixSum;
    }
}
