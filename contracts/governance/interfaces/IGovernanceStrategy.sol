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

    /// @notice Returns the state of a proposal.
    /// @dev Must use the same time reference as `timeType` and revert for unsupported time types.
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

    /// @notice Returns the current total voting power.
    /// @dev Snapshotted by the governance on the first vote of each proposal, so the denominator
    ///      of qualified-majority calculations cannot shrink after votes are recorded.
    function totalVotingPower() external view returns (uint256);

    /// @notice Return the voting period.
    /// @dev Informational only: the enforceable window is the one returned by votingTimestamps.
    /// @return Number of blocks or seconds of period duration, matching the governance's time type.
    function votingPeriod() external view returns (uint256);

    /// @notice Returns the voting timestamps.
    /// @dev Must produce start/end values expressed in the same unit as `timeType` (block numbers
    ///      for TimeType.Blocknumber, timestamps for TimeType.Timestamp). See getProposalState.
    ///      Never reverts: the staking epoch is rolled by `beforePropose` before this is read, and
    ///      a stale or unreadable staking clock falls back to starting the window at the next
    ///      timestamp.
    /// @param timeType Time reference used by the proposal's voting period.
    /// @return startBlockOrTime Timestamp when proposal starts.
    /// @return endBlockOrTime Timestamp when voting ends.
    function votingTimestamps(
        TimeType timeType
    ) external view returns (uint256 startBlockOrTime, uint256 endBlockOrTime);

    /// @notice Return a user's voting power.
    /// @param account Address to check votes for.
    function getVotingPower(address account) external view returns (uint256);

    /// @notice Validates and optionally modifies every action before it is stored as part of a proposal.
    /// @dev Called once per proposal; runs before the voting window is read and may roll the
    ///      staking clock, so it is not a view function.
    /// @param actions The actions to validate.
    /// @return The validated (possibly modified) actions.
    function beforePropose(ProposedAction[] calldata actions) external returns (ProposedAction[] memory);

    /// @notice Returns the actions as they should be executed, optionally modifying their values.
    /// @param actions The actions to execute.
    /// @return The actions to execute.
    function beforeExecute(ProposedAction[] calldata actions) external view returns (ProposedAction[] memory);

    /// @notice Returns the Wormhole core contract used for cross-chain governance.
    /// @return Address of the Wormhole core contract, or the zero address if this chain is not
    ///         configured as a cross-chain governance receiver.
    function wormhole() external view returns (address);

    /// @notice Returns the Wormhole chain id of the chain this strategy is deployed on.
    function wormholeChainId() external view returns (uint16);
}
