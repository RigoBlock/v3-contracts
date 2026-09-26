// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

import "./IGovernanceEvents.sol";

interface IGovernanceVoting {
    enum VoteType {
        For,
        Against,
        Abstain
    }

    /// @notice Casts a vote for the given proposal.
    /// @dev Only callable during the voting period for that proposal. One address can only vote once.
    /// @param proposalId The ID of the proposal to vote on.
    /// @param voteType Whether to support, not support or abstain.
    function castVote(uint256 proposalId, VoteType voteType) external;

    /// @notice Casts a vote for the given proposal, by signature.
    /// @dev Only callable during the voting period for that proposal. One voter can only vote once.
    /// @param proposalId The ID of the proposal to vote on.
    /// @param voteType Whether to support, not support or abstain.
    /// @param v the v field of the signature.
    /// @param r the r field of the signature.
    /// @param s the s field of the signature.
    function castVoteBySignature(uint256 proposalId, VoteType voteType, uint8 v, bytes32 r, bytes32 s) external;

    /// @notice Executes a proposal that has passed and is currently executable.
    /// @param proposalId The ID of the proposal to execute.
    function execute(uint256 proposalId) external payable;

    /// @notice Cancels a proposal that has not started voting yet.
    /// @dev Only the proposer can cancel, and only while the proposal is Pending. A canceled
    ///      proposal cannot be voted on or executed. Cancelling does not consume the proposal id.
    /// @param proposalId The ID of the proposal to cancel.
    function cancel(uint256 proposalId) external;

    struct ProposedAction {
        address target;
        bytes data;
        uint256 value;
    }

    /// @notice Creates a proposal on the the given actions. Must have at least `proposalThreshold`.
    /// @dev Must have at least `proposalThreshold` of voting power to call this function.
    /// @param actions The proposed actions. An action specifies a contract call.
    /// @param description A text description for the proposal.
    /// @return proposalId The ID of the newly created proposal.
    function propose(
        ProposedAction[] calldata actions,
        string calldata description
    ) external returns (uint256 proposalId);
}
