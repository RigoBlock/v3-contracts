// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import {Order} from "gmx-synthetics/order/Order.sol";
import {IBaseOrderUtils} from "gmx-synthetics/order/IBaseOrderUtils.sol";

/// @title IAGmxV2 - Interface for the GMX v2 adapter.
interface IAGmxV2 {
    /// @notice Thrown when the adapter is called directly instead of via delegatecall.
    error DirectCallNotAllowed();

    /// @notice Thrown when deploying on a chain other than Arbitrum.
    error NotArbitrum();

    /// @notice Thrown when the caller passes an order type that is not a valid decrease type.
    error InvalidDecreaseOrderType();

    /// @notice Thrown when the requested execution fee exceeds the protocol maximum (0.05 ETH).
    ///  Prevents pool operators from accidentally (or maliciously) draining the pool's WETH balance.
    error ExecutionFeeExceedsMax();

    /// @notice Emitted when the pool's combined WETH + native ETH balance is insufficient to cover the execution fee.
    error InsufficientNativeBalance();

    /// @notice Parameters for updating an existing pending order.
    /// @param key The unique order key returned by `createIncreaseOrder` or `createDecreaseOrder`.
    /// @param sizeDeltaUsd New size delta in USD (GMX 10^30 precision).
    /// @param acceptablePrice New acceptable execution price.
    /// @param triggerPrice New trigger price for limit/stop-loss orders.
    /// @param minOutputAmount New minimum output amount.
    /// @param validFromTime New valid-from timestamp.
    /// @param autoCancel New auto-cancel flag.
    struct UpdateOrderParams {
        bytes32 key;
        uint256 sizeDeltaUsd;
        uint256 acceptablePrice;
        uint256 triggerPrice;
        uint256 minOutputAmount;
        uint256 validFromTime;
        bool autoCancel;
    }

    // =========================================================================
    // Functions
    // =========================================================================

    /// @notice Opens or increases a leveraged position via a GMX v2 market increase order.
    /// @dev Uses GMX's own CreateOrderParams. The adapter enforces safe values for receiver,
    ///  cancellationReceiver, callbackContract, uiFeeReceiver, swapPath, executionFee,
    ///  callbackGasLimit, shouldUnwrapNativeToken, referralCode, dataList, and orderType
    ///  (always MarketIncrease) — caller-supplied values for these fields are ignored.
    ///  Only addresses.market, addresses.initialCollateralToken, numbers.initialCollateralDeltaAmount,
    ///  numbers.sizeDeltaUsd, numbers.acceptablePrice, and isLong are used from the caller.
    /// @param params GMX CreateOrderParams (security-critical fields are overridden by the adapter).
    /// @return orderKey The unique key of the created GMX order.
    function createIncreaseOrder(
        IBaseOrderUtils.CreateOrderParams calldata params
    ) external returns (bytes32 orderKey);

    /// @notice Decreases or closes a leveraged position via a GMX v2 decrease order.
    /// @dev Uses GMX's own CreateOrderParams. The adapter enforces safe values for receiver,
    ///  cancellationReceiver, callbackContract, uiFeeReceiver, swapPath, executionFee,
    ///  callbackGasLimit, shouldUnwrapNativeToken, referralCode, dataList, and
    ///  decreasePositionSwapType (always NoSwap) — caller-supplied values for these fields are
    ///  ignored. Forcing NoSwap ensures the settlement output is always the collateral token
    ///  (already tracked for NAV); allowing SwapCollateralTokenToPnlToken would return the
    ///  market's index token, which is not in the pool's active-tokens set.
    ///  orderType must be one of MarketDecrease, LimitDecrease, or StopLossDecrease, otherwise
    ///  the call reverts.
    /// @param params GMX CreateOrderParams (security-critical fields are overridden by the adapter).
    /// @return orderKey The unique key of the created GMX order.
    function createDecreaseOrder(
        IBaseOrderUtils.CreateOrderParams calldata params
    ) external returns (bytes32 orderKey);

    /// @notice Updates size, price or fee of an existing pending GMX order.
    /// @dev Tops up the execution fee automatically (same on-chain formula as createOrder).
    ///  Only limit-type orders are updatable; calling on MarketIncrease/Decrease reverts at GMX level.
    /// @param params Parameters with the order key and new values.
    function updateOrder(UpdateOrderParams calldata params) external;

    /// @notice Cancels a pending GMX order and recovers collateral / execution fees back to the pool.
    /// @param key The order key to cancel.
    function cancelOrder(bytes32 key) external;

    /// @notice Claims accumulated funding fees for one or more market/token pairs.
    /// @dev Claimed tokens are sent to the pool and registered in the active tokens set when they
    ///  have a valid price feed in the pool's EOracle extension.
    /// @param markets Array of GMX market addresses to claim from.
    /// @param tokens Array of token addresses corresponding to each market.
    function claimFundingFees(address[] calldata markets, address[] calldata tokens) external;

    /// @notice Claims collateral freed from positions where the negative price impact threshold was exceeded.
    /// @dev Claimed tokens are sent to the pool and registered in the active tokens set when they
    ///  have a valid price feed in the pool's EOracle extension.
    /// @param markets Array of GMX market addresses to claim from.
    /// @param tokens Array of token addresses corresponding to each market.
    /// @param timeKeys Array of time bucket keys identifying each claimable collateral batch.
    function claimCollateral(
        address[] calldata markets,
        address[] calldata tokens,
        uint256[] calldata timeKeys
    ) external;
}
