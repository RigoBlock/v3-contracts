// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {IGovernanceState} from "./governance/IGovernanceState.sol";
import {IGovernanceVoting} from "./governance/IGovernanceVoting.sol";
import {IRigoblockGovernanceFactory} from "./IRigoblockGovernanceFactory.sol";

interface IGovernanceStrategy {
    /// @notice Reverts if initialization paramters are incorrect.
    /// @dev Only used at initialization, as params deleted from factory storage after setup.
    /// @param params Tuple of factory parameters.
    function assertValidInitParams(IRigoblockGovernanceFactory.Parameters calldata params) external view;

    /// @notice Reverts if thresholds are incorrect.
    /// @param proposalThreshold Number of votes required to make a proposal.
    /// @param quorumThreshold Number of votes required for a proposal to succeed.
    function assertValidThresholds(uint256 proposalThreshold, uint256 quorumThreshold) external view;

    /// @notice Returns the state of a proposal for a required quorum.
    /// @param proposal Tuple of the proposal.
    /// @param minimumQuorum Number of votes required for a proposal to pass.
    /// @return Tuple of the proposal state.
    function getProposalState(
        IGovernanceState.Proposal calldata proposal,
        uint256 minimumQuorum
    ) external view returns (IGovernanceState.ProposalState);

    /// @notice Return the voting period.
    /// @return Number of seconds of period duration.
    function votingPeriod() external view returns (uint256);

    /// @notice Returns the voting timestamps.
    /// @return startBlockOrTime Timestamp when proposal starts.
    /// @return endBlockOrTime Timestamp when voting ends.
    function votingTimestamps() external view returns (uint256 startBlockOrTime, uint256 endBlockOrTime);

    /// @notice Return a user's voting power.
    /// @param account Address to check votes for.
    function getVotingPower(address account) external view returns (uint256);

    /// @notice Validates and optionally modifies an action before it is stored as part of a proposal.
    /// @param action The action to validate.
    /// @return The validated (possibly modified) action.
    function beforePropose(IGovernanceVoting.ProposedAction calldata action) external view returns (IGovernanceVoting.ProposedAction memory);

    /// @notice Returns the action as it should be executed, optionally modifying the value.
    /// @param action The action to execute.
    /// @return The action to execute.
    function beforeExecute(IGovernanceVoting.ProposedAction calldata action) external view returns (IGovernanceVoting.ProposedAction memory);
}
