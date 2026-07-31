// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {HyperliquidLib} from "../../../libraries/HyperliquidLib.sol";

/// @title IAHyperliquid - Interface for the Rigoblock Hyperliquid adapter.
/// @notice Exposes manager-facing actions that route to Hyperliquid CoreWriter and CoreDepositWallet.
/// @dev Perps-only, core perp dex (dex 0), USDC collateral. Runs via delegatecall in the pool context.
interface IAHyperliquid {
    // =========================================================================
    // Errors
    // =========================================================================

    error DirectCallNotAllowed();
    error NotHyperEVM();
    error InvalidAsset();
    error InvalidAmount();
    error InvalidToken();
    error InvalidDex();
    error InvalidTif();
    error SlippageExceeded();
    error OnlyCorePerp();
    error ReduceOnlyGtcOnly();
    error OnlyPredictionMarket();
    error PredictionTokenValidationFailed();
    error PredictionTokenAlreadyRegistered();
    error PredictionTokenNotRegistered();
    error PredictionTokenLimitReached();
    error PredictionOrderTooSmall();

    // =========================================================================
    // Events
    // =========================================================================

    event HyperliquidDepositToCore(address indexed token, uint32 indexed destinationDex, uint256 amount);
    event HyperliquidWithdrawFromCore(uint256 indexed amount);
    event HyperliquidUsdClassTransfer(uint256 indexed amount, bool indexed toPerp);
    event HyperliquidPerpOrderSubmitted(
        uint32 indexed asset,
        bool isBuy,
        uint64 limitPx,
        uint64 sz,
        bool reduceOnly,
        uint8 encodedTif,
        uint128 cloid
    );
    event HyperliquidOrderCancelled(bool indexed byCloid, bytes32 indexed key);
    event HyperliquidPredictionTokenRegistered(
        uint64 indexed assetId,
        uint64 indexed spotIndex,
        uint64 indexed tokenIndex
    );
    event HyperliquidPredictionTokenDeregistered(uint64 indexed assetId, uint64 indexed tokenIndex);
    event HyperliquidSpotDeposit(address indexed token, uint256 indexed amount);
    event HyperliquidSpotWithdrawal(address indexed token, uint256 indexed amount);

    // =========================================================================
    // Functions
    // =========================================================================

    /// @notice Bridges USDC from the pool's HyperEVM balance into HyperCore perp margin.
    /// @param token Must be the Hyperliquid USDC collateral token.
    /// @param destinationDex Must be the core perp dex (0). Perps-only integration.
    /// @param amount Amount of USDC to deposit.
    function depositToCore(address token, uint32 destinationDex, uint256 amount) external;

    /// @notice Submits a core perp limit order via the Hyperliquid CoreWriter.
    /// @dev Only IOC and GTC time-in-force are accepted. GTC orders must be reduce-only (stop-loss/take-profit).
    ///  IOC orders are slippage-checked against the Hyperliquid oracle precompile.
    ///  Only core perp assets (assetId < 10_000) are allowed.
    function submitPerpOrder(HyperliquidLib.LimitOrderParams calldata params) external;

    /// @notice Cancels pending orders by OID.
    /// @param oids Array of order IDs to cancel.
    function cancelPerpOrderByOids(uint32[] calldata oids) external;

    /// @notice Cancels pending orders by CLOID.
    /// @param cloids Array of client order IDs to cancel.
    function cancelPerpOrderByCloids(uint128[] calldata cloids) external;

    /// @notice Bridges USDC from HyperCore spot back to the pool's HyperEVM balance.
    /// @param amount Amount of USDC (6 decimals) to bridge.
    /// @dev Encodes a `spotSend` action (action 6) with the USDC system address as destination. The USDC must
    ///  have been moved to the HyperCore spot dex (e.g. via `transferUsdClass`) before calling this function.
    function withdrawFromCore(uint256 amount) external;

    /// @notice Transfers USDC between the HyperCore perp and spot margin classes.
    /// @param amount Amount of USDC (6 decimals) to transfer.
    /// @param toPerp If true, moves USDC from spot to perp; otherwise from perp to spot.
    /// @dev Required to consolidate USDC into spot before withdrawing to HyperEVM.
    function transferUsdClass(uint256 amount, bool toPerp) external;

    /// @notice Bridges USDC from the pool's HyperEVM balance into the HyperCore spot dex.
    /// @param token Must be the Hyperliquid USDC collateral token.
    /// @param amount Amount of USDC to deposit.
    /// @dev This is the first step for trading HIP-4 prediction markets or any spot asset on HyperCore.
    function depositToSpot(address token, uint256 amount) external;

    /// @notice Bridges USDC from the HyperCore spot dex back to the pool's HyperEVM balance.
    /// @param amount Amount of USDC (6 decimals) to withdraw.
    function withdrawFromSpot(uint256 amount) external;

    /// @notice Registers a HIP-4 outcome token for NAV tracking.
    /// @param assetId The HIP-4 outcome asset ID (>= 100_000_000).
    /// @param spotIndex The index of the spot market in Hyperliquid spotMeta.
    /// @param tokenIndex The Hyperliquid token index for the outcome side being tracked.
    /// @dev The manager must register each outcome token because its token index cannot be derived from the asset ID alone.
    function registerPredictionToken(uint64 assetId, uint64 spotIndex, uint64 tokenIndex) external;

    /// @notice Deregisters a HIP-4 outcome token that no longer has a balance.
    /// @param assetId The HIP-4 outcome asset ID.
    /// @param tokenIndex The Hyperliquid token index to deregister.
    function deregisterPredictionToken(uint64 assetId, uint64 tokenIndex) external;

    /// @notice Submits a limit order for a HIP-4 outcome market.
    /// @param params Standard Hyperliquid limit order parameters. `asset` must be a registered HIP-4 asset.
    /// @dev Restricted to IOC/GTC time-in-force. IOC orders are slippage-checked against the Hyperliquid spot precompile.
    function submitPredictionOrder(HyperliquidLib.LimitOrderParams calldata params) external;
}
