// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {EventUtils} from "gmx-synthetics/event/EventUtils.sol";

/// @title IEGmxCallback
/// @notice GMX v2 order execution callback extension interface.
interface IEGmxCallback {
    /// @notice Emitted when a market is added to the tracked-markets set.
    event TrackedMarketAdded(address indexed market);

    /// @notice Emitted when a claimable-collateral key is recorded.
    event ClaimableCollateralAdded(
        bytes32 indexed claimableCollateralKey,
        address indexed token,
        address indexed market,
        uint256 timeKey
    );

    /// @notice Emitted when a market is removed from the tracked-markets set.
    event TrackedMarketRemoved(address indexed market);

    /// @notice Emitted when a fully-claimed collateral key is removed.
    event ClaimableCollateralRemoved(bytes32 indexed claimableCollateralKey);

    /// @notice Called by GMX after an order affecting this pool is executed.
    /// @param key The GMX order key.
    /// @param orderData Event log data describing the order.
    /// @param eventData Additional event data from GMX.
    function afterOrderExecution(
        bytes32 key,
        EventUtils.EventLogData memory orderData,
        EventUtils.EventLogData memory eventData
    ) external;
}
