// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

/// @title LighterTypes
/// @notice ABI layouts of the LighterCore state reads returned by the READ_CORE precompile.
/// @dev Kept next to the Lighter predeploy interfaces so a future lighter-contracts git submodule
///  can replace this single file as the source of truth. Every read except tx status (0x0000)
///  returns the abi.encode(bool found, bytes data) envelope; the structs are the inner payload.
library LighterTypes {
    /// @notice READ_CORE 0x0001 (account info). collateralBaseAmount is the shared USDC margin
    ///  (1e6 per USDC; excludes isolated margin). found=false means the account does not exist.
    struct AccountInfo {
        uint8 accountType;
        uint48 accountIndex;
        uint48 masterAccountIndex;
        address l1Address;
        address evmAddress;
        int128 collateralBaseAmount;
    }

    /// @notice READ_CORE 0x0005 (market info). quoteMultiplier converts amount * price to USDC
    ///  base units (value = amount * price * quoteMultiplier); fundingRatePrefixSum and
    ///  lastFundingRoundTimestamp feed the pending-funding calculation. Prices are on the market
    ///  scales of createOrder. baseAssetId/quoteAssetId are 0 for perpetuals.
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

    /// @notice READ_CORE 0x0007 (position). size is signed (positive long); entryQuote is the
    ///  unsigned entry notional in USDC base units; allocatedMargin is USDC base units (isolated
    ///  only); lastFundingRatePrefixSum feeds the pending-funding calculation.
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
