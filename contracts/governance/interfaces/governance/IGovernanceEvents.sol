// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import "./IGovernanceVoting.sol";

interface IGovernanceEvents {
    /// @notice Emitted when a new proposal is created.
    /// @param proposer Address of the proposer.
    /// @param proposalId Number of the proposal.
    /// @param actions Struct array of actions (targets, datas, values).
    /// @param startBlockOrTime Timestamp in seconds after which proposal can be voted on.
    /// @param endBlockOrTime Timestamp in seconds after which proposal can be executed.
    /// @param description String description of proposal.
    event ProposalCreated(
        address proposer,
        uint256 proposalId,
        IGovernanceVoting.ProposedAction[] actions,
        uint256 startBlockOrTime,
        uint256 endBlockOrTime,
        string description
    );

    /// @notice Emitted when a proposal is executed.
    /// @param proposalId Number of the proposal.
    event ProposalExecuted(uint256 proposalId);

    /// @notice Emmited when the governance strategy is upgraded.
    /// @param newStrategy Address of the new strategy contract.
    event StrategyUpgraded(address newStrategy);

    /// @notice Emitted when voting thresholds get updated.
    /// @dev Only governance can update thresholds.
    /// @param proposalThreshold Number of votes required to add a proposal.
    /// @param quorumThreshold Number of votes required to execute a proposal.
    event ThresholdsUpdated(uint256 proposalThreshold, uint256 quorumThreshold);

    /// @notice Emitted when implementation written to proxy storage.
    /// @dev Emitted also at first variable initialization.
    /// @param newImplementation Address of the new implementation.
    event Upgraded(address indexed newImplementation);

    /// @notice Emitted when a voter votes.
    /// @param voter Address of the voter.
    /// @param proposalId Number of the proposal.
    /// @param voteType Number of vote type.
    /// @param votingPower Number of votes.
    event VoteCast(address voter, uint256 proposalId, IGovernanceVoting.VoteType voteType, uint256 votingPower);
}
