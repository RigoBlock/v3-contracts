// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

import {IGovernanceState} from "./governance/IGovernanceState.sol";
import {IGovernanceVoting} from "./governance/IGovernanceVoting.sol";
import {IRigoblockGovernanceFactory} from "./IRigoblockGovernanceFactory.sol";
import {ProposalStatus} from "../types/GovernanceTypes.sol";
import {TimeType} from "../types/TimeType.sol";

interface IGovernanceStrategy {
    /// @notice Emitted when a recovery is requested.
    event RecoverRequested(uint256 timestamp);

    /// @notice Emitted when a recovery is rejected.
    event RecoverRejected();

    /// @notice Thrown when a local governance method is called on a receiver-only chain.
    error GovLocalGovernanceDisabled();

    /// @notice Thrown when a Wormhole cross-chain action has malformed calldata.
    error GovCrosschainInvalidData();

    /// @notice Thrown when a Wormhole cross-chain action targets the current chain.
    error GovCrosschainTargetSelf(uint16 targetChainId);

    /// @notice Thrown when a non-sender governance attempts to create a cross-chain proposal.
    error GovCrosschainNotSender();

    /// @notice Thrown when a Wormhole cross-chain action carries a non-zero wrapper value.
    error GovCrosschainInvalidValue(uint256 value);

    /// @notice Thrown when a Wormhole message is published with a non-finalized consistency level.
    /// @param consistencyLevel The supplied consistency level.
    error GovCrosschainInvalidConsistencyLevel(uint8 consistencyLevel);

    /// @notice Thrown when the proposal threshold is outside the allowed range.
    error GovStrategyInvalidProposalThreshold(uint256 proposalThreshold, uint256 floor, uint256 cap);

    /// @notice Thrown when the quorum threshold is outside the allowed range.
    error GovStrategyInvalidQuorumThreshold(uint256 quorumThreshold, uint256 floor, uint256 cap);

    /// @notice Thrown when the governance time type is not TimeType.Timestamp.
    error GovStrategyInvalidTimeType(TimeType timeType);

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

    /// @notice Reverts if initialization paramters are incorrect.
    /// @dev Only used at initialization, as params deleted from factory storage after setup.
    /// @param params Tuple of factory parameters.
    function assertValidInitParams(IRigoblockGovernanceFactory.Parameters calldata params) external view;

    /// @notice Reverts if the proposal threshold is incorrect.
    /// @param proposalThreshold Number of votes required to make a proposal.
    function assertValidProposalThreshold(uint256 proposalThreshold) external view;

    /// @notice Reverts if the quorum threshold is incorrect.
    /// @param quorumThreshold Number of votes required for a proposal to succeed.
    function assertValidQuorumThreshold(uint256 quorumThreshold) external view;

    /// @notice Returns the state of a proposal for a required quorum.
    /// @dev Must use the same time reference as `timeType` and revert for unsupported time types.
    /// @param proposal Tuple of the proposal.
    /// @param minimumQuorum Number of votes required for a proposal to pass.
    /// @param timeType Time reference used by the proposal's voting period.
    /// @return Tuple of the proposal state.
    function getProposalState(
        IGovernanceState.Proposal calldata proposal,
        uint256 minimumQuorum,
        TimeType timeType
    ) external view returns (ProposalStatus);

    /// @notice Return the voting period.
    /// @dev Informational only: the enforceable window is the one returned by votingTimestamps.
    /// @return Number of blocks or seconds of period duration, matching the governance's time type.
    function votingPeriod() external view returns (uint256);

    /// @notice Returns the voting timestamps.
    /// @dev Must produce start/end values expressed in the same unit as `timeType` (block numbers
    ///      for TimeType.Blocknumber, timestamps for TimeType.Timestamp). See getProposalState.
    /// @param timeType Time reference used by the proposal's voting period.
    /// @return startBlockOrTime Timestamp when proposal starts.
    /// @return endBlockOrTime Timestamp when voting ends.
    function votingTimestamps(
        TimeType timeType
    ) external view returns (uint256 startBlockOrTime, uint256 endBlockOrTime);

    /// @notice Return a user's voting power.
    /// @param account Address to check votes for.
    function getVotingPower(address account) external view returns (uint256);

    /// @notice Validates and optionally modifies an action before it is stored as part of a proposal.
    /// @param action The action to validate.
    /// @return The validated (possibly modified) action.
    function beforePropose(
        IGovernanceVoting.ProposedAction calldata action
    ) external view returns (IGovernanceVoting.ProposedAction memory);

    /// @notice Returns the action as it should be executed, optionally modifying the value.
    /// @param action The action to execute.
    /// @return The action to execute.
    function beforeExecute(
        IGovernanceVoting.ProposedAction calldata action
    ) external view returns (IGovernanceVoting.ProposedAction memory);

    /// @notice Returns the Wormhole core contract used for cross-chain governance.
    /// @return Address of the Wormhole core contract, or the zero address if this chain is not
    ///         configured as a cross-chain governance receiver.
    function wormhole() external view returns (address);

    /// @notice Returns the Wormhole chain id of the chain this strategy is deployed on.
    function wormholeChainId() external view returns (uint16);
}
