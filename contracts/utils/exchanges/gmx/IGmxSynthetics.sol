// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

// =============================================================================
// GMX v2 (gmx-synthetics) Interfaces — Rigoblock Thin Wrapper
// =============================================================================
// Three pure struct libraries (Price, Market, Position) are imported directly
// from the gmx-synthetics submodule: they have zero external dependencies.
//
// PositionPricingUtils, ReaderPositionUtils, ReaderPricingUtils, and MarketUtils
// transitively import @openzeppelin which is NOT in this project's dependency
// tree.  Their ABI layouts are reproduced here verbatim as hand-defined structs.
// Field order is authoritative and MUST exactly match the on-chain encoding
// produced by the deployed Reader contract.
//
// Order.sol and IBaseOrderUtils are imported directly from the gmx-synthetics
// submodule — their import chain is clean (Order → Chain → ArbSys/ArbGasInfo,
// both pure interfaces with zero external dependencies).
//
// Canonical Arbitrum addresses (source: gmx-io/gmx-synthetics deployments/arbitrum/):
//   ExchangeRouter              0x1C3fa76e6E1088bCE750f23a5BFcffa1efEF6A41
//   DataStore                   0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8
//   Reader                      0x470fbC46bcC0f16532691Df360A07d8Bf5ee0789
//   ChainlinkPriceFeedProvider  0x38B8dB61b724b51e42A88Cb8eC564CD685a0f53B
//   ReferralStorage             0xe6fab3F0c7199b0d34d7FbE83394fc0e0D06e99d
//   RoleStore                   0x3c3d99FD298f679DBC2CEcd132b4eC4d0F5e6e72
// =============================================================================

// ---------------------------------------------------------------------------
// Lightweight canonical imports — no transitive external dependencies
// ---------------------------------------------------------------------------
import {Price} from "gmx-synthetics/price/Price.sol";
import {Market} from "gmx-synthetics/market/Market.sol";
import {Position} from "gmx-synthetics/position/Position.sol";
import {Order} from "gmx-synthetics/order/Order.sol";
import {IBaseOrderUtils} from "gmx-synthetics/order/IBaseOrderUtils.sol";

// ---------------------------------------------------------------------------
// Hand-defined ABI-compatible structs
// Field order MUST exactly mirror the on-chain ABI of the deployed contracts.
// Source struct definitions: lib/gmx-synthetics/contracts/
// ---------------------------------------------------------------------------

// ---- PositionPricingUtils nested fee structs --------------------------------

/// @dev PositionPricingUtils.PositionReferralFees
struct GmxPositionReferralFees {
    bytes32 referralCode;
    address affiliate;
    address trader;
    uint256 totalRebateFactor;
    uint256 affiliateRewardFactor;
    uint256 adjustedAffiliateRewardFactor;
    uint256 traderDiscountFactor;
    uint256 totalRebateAmount;
    uint256 traderDiscountAmount;
    uint256 affiliateRewardAmount;
}

/// @dev PositionPricingUtils.PositionProFees
struct GmxPositionProFees {
    uint256 traderTier;
    uint256 traderDiscountFactor;
    uint256 traderDiscountAmount;
}

/// @dev PositionPricingUtils.PositionFundingFees
struct GmxPositionFundingFees {
    uint256 fundingFeeAmount;
    uint256 claimableLongTokenAmount;
    uint256 claimableShortTokenAmount;
    uint256 latestFundingFeeAmountPerSize;
    uint256 latestLongTokenClaimableFundingAmountPerSize;
    uint256 latestShortTokenClaimableFundingAmountPerSize;
}

/// @dev PositionPricingUtils.PositionBorrowingFees
struct GmxPositionBorrowingFees {
    uint256 borrowingFeeUsd;
    uint256 borrowingFeeAmount;
    uint256 borrowingFeeReceiverFactor;
    uint256 borrowingFeeAmountForFeeReceiver;
}

/// @dev PositionPricingUtils.PositionUiFees
struct GmxPositionUiFees {
    address uiFeeReceiver;
    uint256 uiFeeReceiverFactor;
    uint256 uiFeeAmount;
}

/// @dev PositionPricingUtils.PositionLiquidationFees
struct GmxPositionLiquidationFees {
    uint256 liquidationFeeUsd;
    uint256 liquidationFeeAmount;
    uint256 liquidationFeeReceiverFactor;
    uint256 liquidationFeeAmountForFeeReceiver;
}

/// @dev PositionPricingUtils.PositionFees
struct GmxPositionFees {
    GmxPositionReferralFees referral;
    GmxPositionProFees pro;
    GmxPositionFundingFees funding;
    GmxPositionBorrowingFees borrowing;
    GmxPositionUiFees ui;
    GmxPositionLiquidationFees liquidation;
    Price.Props collateralTokenPrice;
    uint256 positionFeeFactor;
    uint256 protocolFeeAmount;
    uint256 positionFeeReceiverFactor;
    uint256 feeReceiverAmount;
    uint256 feeAmountForPool;
    uint256 positionFeeAmountForPool;
    uint256 positionFeeAmount;
    uint256 totalCostAmountExcludingFunding;
    uint256 totalCostAmount;
    uint256 totalDiscountAmount;
}

// ---- ReaderPricingUtils.ExecutionPriceResult --------------------------------

/// @dev ReaderPricingUtils.ExecutionPriceResult
struct GmxExecutionPriceResult {
    int256 priceImpactUsd;
    uint256 executionPrice;
    bool balanceWasImproved;
    int256 proportionalPendingImpactUsd;
    int256 totalImpactUsd;
    uint256 priceImpactDiffUsd;
}

// ---- ReaderPositionUtils.PositionInfo --------------------------------------

/// @dev ReaderPositionUtils.PositionInfo — returned by Reader.getAccountPositionInfoList
struct GmxPositionInfo {
    bytes32 positionKey;
    Position.Props position;
    GmxPositionFees fees;
    GmxExecutionPriceResult executionPriceResult;
    int256 basePnlUsd;
    int256 uncappedBasePnlUsd;
    int256 pnlAfterPriceImpactUsd;
}

// ---- MarketUtils.MarketPrices -----------------------------------------------

/// @dev MarketUtils.MarketPrices — input to Reader.getAccountPositionInfoList
struct GmxMarketPrices {
    Price.Props indexTokenPrice;
    Price.Props longTokenPrice;
    Price.Props shortTokenPrice;
}

// ---- Order.Props (for Reader.getAccountOrders) -----------------------------
// Order.Addresses, Order.Numbers, Order.Flags, Order.Props, Order.OrderType,
// and Order.DecreasePositionSwapType are imported directly from Order.sol above.

/// @dev ReaderUtils.OrderInfo — element type returned by Reader.getAccountOrders.
///  The outer wrapper adds an order key (the first field) before the nested Order.Props.
struct GmxOrderInfo {
    bytes32 orderKey;
    Order.Props order;
}

// ---------------------------------------------------------------------------
// GMX price types
// ---------------------------------------------------------------------------

/// @dev Validated price returned by the GMX Chainlink price feed provider.
///  Not part of PositionInfo ABI — standalone return type only.
struct GmxValidatedPrice {
    address token;
    uint256 min;
    uint256 max;
    uint256 timestamp;
    uint256 blockNumber;
}

// ---------------------------------------------------------------------------
// ExchangeRouter interface
// ---------------------------------------------------------------------------

/// @dev Subset of the GMX v2 ExchangeRouter interface used by AGmxV2.
///  Order creation uses IBaseOrderUtils.CreateOrderParams imported above.
interface IGmxExchangeRouter {
    function orderHandler() external view returns (IGmxOrderHandler);

    function createOrder(IBaseOrderUtils.CreateOrderParams calldata params) external payable returns (bytes32);

    function updateOrder(
        bytes32 key,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice,
        uint256 triggerPrice,
        uint256 minOutputAmount,
        uint256 validFromTime,
        bool autoCancel
    ) external payable;

    function cancelOrder(bytes32 key) external payable;

    function claimFundingFees(
        address[] calldata markets,
        address[] calldata tokens,
        address receiver
    ) external payable returns (uint256[] memory claimedAmounts);

    function claimCollateral(
        address[] calldata markets,
        address[] calldata tokens,
        uint256[] calldata timeKeys,
        address receiver
    ) external payable returns (uint256[] memory claimedAmounts);
}

// ---------------------------------------------------------------------------
// OrderHandler interface
// ---------------------------------------------------------------------------

/// @dev Provides access to the GMX order vault address and order execution.
interface IGmxOrderHandler {
    struct SetPricesParams {
        address[] tokens;
        address[] providers;
        bytes[] data;
    }

    function orderVault() external view returns (address);

    /// @dev Executes an order.  Called by keeper; oracle providers must already
    ///  be set in DataStore.  In fork tests, swap the oracle provider to
    ///  Chainlink before calling this.
    function executeOrder(bytes32 key, SetPricesParams calldata oracleParams) external;
}

// ---------------------------------------------------------------------------
// Reader interface
// ---------------------------------------------------------------------------

/// @dev Subset of the GMX v2 Reader interface used by AGmxV2, EApps, and GmxLib.
interface IGmxReader {
    /// @dev Returns raw position structs without price evaluation.
    ///  The `end` parameter is clamped to the actual array length, so
    ///  passing `type(uint256).max` safely returns all positions.
    function getAccountPositions(
        address dataStore,
        address account,
        uint256 start,
        uint256 end
    ) external view returns (Position.Props[] memory);

    /// @dev Returns detailed position info including PnL and all fees (requires market prices).
    ///  Uses hand-defined ABI-compatible structs — no transitive heavy imports.
    function getAccountPositionInfoList(
        address dataStore,
        address referralStorage,
        address account,
        address[] memory markets,
        GmxMarketPrices[] memory prices,
        address uiFeeReceiver,
        uint256 start,
        uint256 end
    ) external view returns (GmxPositionInfo[] memory);

    /// @dev Returns all pending orders for `account`.
    ///  Passing `type(uint256).max` for `end` safely returns all orders.
    function getAccountOrders(
        address dataStore,
        address account,
        uint256 start,
        uint256 end
    ) external view returns (GmxOrderInfo[] memory);

    /// @dev Returns market properties (index/long/short tokens) for a given market token.
    function getMarket(address dataStore, address market) external view returns (Market.Props memory);
}

// ---------------------------------------------------------------------------
// RoleStore interface — used in tests to look up keeper address
// ---------------------------------------------------------------------------

/// @dev Minimal interface to GMX RoleStore for test infrastructure.
interface IGmxRoleStore {
    /// @dev Returns members holding `roleKey` in the range [start, end).
    function getRoleMembers(bytes32 roleKey, uint256 start, uint256 end) external view returns (address[] memory);
}

// ---------------------------------------------------------------------------
// ChainlinkPriceFeedProvider interface
// ---------------------------------------------------------------------------

/// @dev Queries on-chain Chainlink price feeds in GMX price format.
///  Deployed on Arbitrum at 0x38B8dB61b724b51e42A88Cb8eC564CD685a0f53B.
interface IGmxChainlinkPriceFeedProvider {
    /// @dev Returns the latest validated price for `token`.  Pass `data = ""`.
    function getOraclePrice(address token, bytes memory data) external view returns (GmxValidatedPrice memory);
}

// ---------------------------------------------------------------------------
// DataStore interface — used for execution fee estimation
// ---------------------------------------------------------------------------

/// @dev Minimal interface to GMX DataStore for reading configuration values.
interface IGmxDataStore {
    /// @dev Returns the uint256 value stored at `key`.
    function getUint(bytes32 key) external view returns (uint256);
}



