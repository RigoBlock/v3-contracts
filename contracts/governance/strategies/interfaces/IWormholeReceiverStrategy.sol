// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

/// @title IWormholeReceiverStrategy - Receiver-chain governance escape hatch.
/// @notice Receiver strategies are staking-free: local governance is fail-closed and the only
///         execution path is cross-chain messages delivered from the sender chain. If the
///         bridge fails, the pre-designated recovery address can request local governance
///         after a challenge window, during which the sender-side governance can veto.
interface IWormholeReceiverStrategy {
    /// @notice Emitted when a recovery is requested.
    event RecoverRequested(uint256 timestamp);

    /// @notice Emitted when a recovery is rejected.
    event RecoverRejected();

    /// @notice Thrown when a local governance method is called while recovery is not active.
    error GovLocalGovernanceDisabled();

    /// @notice Thrown when a proposal on a non-sender chain targets the Wormhole core.
    error GovCrosschainNotSender();

    /// @notice Thrown when an address other than the recovery address or the governance proxy
    ///      attempts to manage a recovery request.
    error GovRecoveryUnauthorized(address caller);

    /// @notice Thrown when a recovery request is pending or already active.
    error GovRecoveryAlreadyPending();

    /// @notice Thrown when no recovery request is pending.
    error GovRecoveryNotPending();

    /// @notice Thrown when a receiver-chain strategy is deployed without a recovery address.
    error GovRecoveryAddressZero();

    /// @notice Requests the governance recovery; executable after the challenge window.
    /// @dev Only callable by the recovery address, and only when no request is pending or active.
    function requestRecover() external;

    /// @notice Rejects a pending or active recovery (the governance's veto).
    /// @dev Only callable by the governance proxy, i.e. as a delivered governance action.
    function rejectRecover() external;
}
