// SPDX-License-Identifier: Apache-2.0
/*

  Copyright 2023 Rigo Intl.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/

pragma solidity ^0.8.17;
pragma experimental ABIEncoderV2;

interface IRigoblockGovernance {
    /// @notice Emitted when implementation written to proxy storage.
    /// @dev Emitted also at first variable initialization.
    /// @param newImplementation Address of the new implementation.
    event Upgraded(address indexed newImplementation);

    struct TreasuryParameters {
        uint256 votingPeriod;
        uint256 proposalThreshold;
        uint256 quorumThreshold;
    }

    struct ProposedAction {
        address target;
        bytes data;
        uint256 value;
    }

    enum VoteType {
        FOR,
        AGAINST,
        ABSTAIN
    }

    struct Proposal {
        bytes32 actionsHash;
        uint256 executionEpoch;
        uint256 voteEpoch;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 votesAbstain;
        bool executed;
    }

    event ProposalCreated(
        address proposer,
        uint256 proposalId,
        ProposedAction[] actions,
        uint256 executionEpoch,
        string description
    );

    event VoteCast(address voter, uint256 proposalId, VoteType voteType, uint256 votingPower);

    event ProposalExecuted(uint256 proposalId);

    function stakingProxy() external view returns (address);

    function votingPeriod() external view returns (uint256);

    function proposalThreshold() external view returns (uint256);

    function quorumThreshold() external view returns (uint256);

    /// @notice Initializes the Rigoblock Governance.
    /// @param stakingProxy_ The Rigoblock staking proxy address.
    /// @param params Immutable treasury parameters.
    function initializeGovernance(address stakingProxy_, TreasuryParameters memory params) external;

    // TODO: add docs
    /// @dev Only callable after successful voting.
    function upgradeImplementation(address newImplementation) external;

    /// @dev Updates the proposal and quorum thresholds to the given
    ///      values. Note that this function is only callable by the
    ///      treasury contract itself, so the threshold can only be
    ///      updated via a successful treasury proposal.
    /// @param newProposalThreshold The new value for the proposal threshold.
    /// @param newQuorumThreshold The new value for the quorum threshold.
    function updateThresholds(uint256 newProposalThreshold, uint256 newQuorumThreshold) external;

    /// @notice Creates a proposal on the the given actions. Must have at least `proposalThreshold`.
    /// @dev Must have at least `proposalThreshold` of voting power to call this function.
    /// @dev If a proposal is successfully created, voting starts at the epoch after next (currentEpoch + 2).
    /// @dev If the vote passes, the proposal is executable during the `executionEpoch`.
    /// @param actions The proposed actions. An action specifies a contract call.
    /// @param executionEpoch The epoch during which the proposal is to be executed if it passes.
    ///     Must be at least two epochs from the current epoch.
    /// @param description A text description for the proposal.
    /// @return proposalId The ID of the newly created proposal.
    function propose(
        ProposedAction[] calldata actions,
        uint256 executionEpoch,
        string calldata description
    ) external returns (uint256 proposalId);

    /// @dev Casts a vote for the given proposal. Only callable
    ///      during the voting period for that proposal.
    ///      One address can only vote once.
    ///      See `getVotingPower` for how voting power is computed.
    /// @param proposalId The ID of the proposal to vote on.
    /// @param voteType Whether to support the proposal or not.
    function castVote(uint256 proposalId, VoteType voteType) external;

    /// @dev Casts a vote for the given proposal, by signature.
    ///      Only callable during the voting period for that proposal.
    ///      One address/voter can only vote once.
    ///      See `getVotingPower` for how voting power is computed.
    /// @param proposalId The ID of the proposal to vote on.
    /// @param voteType Whether to support the proposal or not.
    /// @param v the v field of the signature
    /// @param r the r field of the signature
    /// @param s the s field of the signature
    function castVoteBySignature(
        uint256 proposalId,
        VoteType voteType,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /// @dev Executes a proposal that has passed and is
    ///      currently executable.
    /// @param proposalId The ID of the proposal to execute.
    /// @param actions Actions associated with the proposal to execute.
    function execute(uint256 proposalId, ProposedAction[] memory actions) external payable;

    /// @dev Returns the total number of proposals.
    /// @return count The number of proposals.
    function proposalCount() external view returns (uint256 count);

    // @notice Computes the current voting power of the given account.
    /// @dev Voting power is equal to staked delegated GRG.
    /// @param account The address of the account.
    /// @return votingPower The current voting power of the given account.
    function getVotingPower(
        address account
    ) external view returns (uint256 votingPower);
}
