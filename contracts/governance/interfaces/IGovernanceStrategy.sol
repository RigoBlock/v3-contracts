// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

import {IGovernanceState} from "./governance/IGovernanceState.sol";
import {IRigoblockGovernanceFactory} from "./IRigoblockGovernanceFactory.sol";
import {ProposalStatus, ProposedAction} from "../types/GovernanceTypes.sol";
import {TimeType} from "../types/TimeType.sol";

interface IGovernanceStrategy {
    /// @notice Thrown when a Wormhole cross-chain action has malformed calldata.
    error GovCrosschainInvalidData();

    /// @notice Thrown when a Wormhole cross-chain action targets the current chain.
    error GovCrosschainTargetSelf(uint16 targetChainId);

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

    /// @notice Reverts unless the governance parameters are valid for this strategy.
    /// @dev Called directly at initialization and by `updateThresholds` at execution time.
    /// @param params Tuple of factory parameters.
    function validateParams(IRigoblockGovernanceFactory.Parameters calldata params) external view;

    /// @notice Returns the state of a proposal.
    /// @dev Must use the same time reference as `timeType` and revert for unsupported time types.
    ///      The implementation passes the stored proposal, whose `executed` flag must be honored
    ///      first: executed is terminal and must be reported regardless of clock or recovery state.
    /// @param proposal Tuple of the proposal.
    /// @param proposer The stored proposal proposer.
    /// @param minimumQuorum Number of votes required for a proposal to pass.
    /// @param votingPower Total voting power snapshotted by the governance on the first vote.
    /// @param timeType Time reference used by the proposal's voting period.
    /// @return Tuple of the proposal state.
    function getProposalState(
        IGovernanceState.Proposal calldata proposal,
        address proposer,
        uint256 minimumQuorum,
        uint256 votingPower,
        TimeType timeType
    ) external view returns (ProposalStatus);

    /// @notice Return the voting period.
    /// @dev Informational only: the enforceable window is the one returned by `beforePropose`.
    /// @return Number of blocks or seconds of period duration, matching the governance's time type.
    function votingPeriod() external view returns (uint256);

    /// @notice Return a user's voting power.
    /// @param account Address to check votes for.
    function getVotingPower(address account) external view returns (uint256);

    /// @notice Validates and optionally modifies the actions before they are stored, and returns
    ///         the proposal's fixed voting window.
    /// @dev Called once per proposal. The returned start/end are stored in the proposal: they are
    ///      fixed pointers, not a rolling window, so this is not a view function (it may roll the
    ///      staking clock).
    function beforePropose(
        ProposedAction[] calldata actions
    ) external returns (ProposedAction[] memory, uint256 startBlockOrTime, uint256 endBlockOrTime);

    /// @notice Called by the governance before every vote.
    /// @return totalVotingPower The current total voting power. The governance stores it as the
    ///         proposal's voting-power snapshot on the first vote; the fixed snapshot is the
    ///         qualified-majority denominator for the proposal's whole life.
    function beforeVote() external returns (uint256 totalVotingPower);

    /// @notice Returns the actions as they should be executed, optionally modifying their values.
    /// @param actions The actions to execute.
    /// @return The actions to execute.
    function beforeExecute(ProposedAction[] calldata actions) external view returns (ProposedAction[] memory);

    /// @notice Returns the Wormhole core contract used for cross-chain governance.
    /// @return Address of the Wormhole core contract, or the zero address if this chain is not
    ///         configured as a cross-chain governance receiver.
    function wormhole() external view returns (address);
}
