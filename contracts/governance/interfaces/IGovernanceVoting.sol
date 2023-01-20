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

pragma solidity >=0.8.0 <0.9.0;

import "./IGovernanceEvents.sol";

interface IGovernanceVoting {
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
        IGovernanceEvents.ProposedAction[] calldata actions,
        uint256 executionEpoch,
        string calldata description
    ) external returns (uint256 proposalId);

    /// @dev Casts a vote for the given proposal. Only callable
    ///      during the voting period for that proposal.
    ///      One address can only vote once.
    ///      See `getVotingPower` for how voting power is computed.
    /// @param proposalId The ID of the proposal to vote on.
    /// @param voteType Whether to support the proposal or not.
    function castVote(uint256 proposalId, IGovernanceEvents.VoteType voteType) external;

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
        IGovernanceEvents.VoteType voteType,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /// @dev Executes a proposal that has passed and is
    ///      currently executable.
    /// @param proposalId The ID of the proposal to execute.
    /// @param actions Actions associated with the proposal to execute.
    function execute(uint256 proposalId, IGovernanceEvents.ProposedAction[] memory actions) external payable;
}