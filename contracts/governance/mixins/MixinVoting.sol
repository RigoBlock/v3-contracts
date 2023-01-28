// SPDX-License-Identifier: Apache 2.0
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

import "./MixinAbstract.sol";
import "./MixinStorage.sol";
import "../interfaces/IGovernanceStrategy.sol";

abstract contract MixinVoting is MixinStorage, MixinAbstract {
    /// @inheritdoc IGovernanceVoting
    function propose(
        ProposedAction[] memory actions,
        string memory description
    ) external override returns (uint256 proposalId) {
        uint256 length = actions.length;
        require(_getVotingPower(msg.sender) >= _governanceParameters().proposalThreshold, "GOV_LOW_VOTING_POWER");
        require(length > 0, "GOV_NO_ACTIONS_ERROR");
        require(length <= PROPOSAL_MAX_OPERATIONS, "GOV_TOO_MANY_ACTIONS_ERROR");
        (uint256 startBlockOrTime, uint256 endBlockOrTime) = IGovernanceStrategy(_governanceStrategy().value).votingTimestamps();

        proposalId = _getProposalCount();
        Proposal memory newProposal = Proposal({
            actionsLength: length,
            startBlockOrTime: startBlockOrTime,
            endBlockOrTime: endBlockOrTime,
            votesFor: 0,
            votesAgainst: 0,
            votesAbstain: 0,
            executed: false
        });

        for (uint i; i < length; ++i) {
            _proposedAction().proposedActionbyIndex[proposalId][i] = actions[i];
        }

        _proposals().proposalById[proposalId] = newProposal;
        ++_proposalCount().value;

        emit ProposalCreated(msg.sender, proposalId, actions, startBlockOrTime, endBlockOrTime, description);
    }

    /// @inheritdoc IGovernanceVoting
    function castVote(uint256 proposalId, VoteType voteType) external override {
        return _castVote(msg.sender, proposalId, voteType);
    }

    /// @inheritdoc IGovernanceVoting
    function castVoteBySignature(
        uint256 proposalId,
        VoteType voteType,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        // TODO: read from public method
        bytes32 structHash = keccak256(abi.encode(VOTE_TYPEHASH, proposalId, voteType));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator().value, structHash));
        address signatory = ecrecover(digest, v, r, s);

        return _castVote(signatory, proposalId, voteType);
    }

    /// @inheritdoc IGovernanceVoting
    function execute(uint256 proposalId) external payable override {
        require(proposalId < _getProposalCount(), "VOTING_INVALID_PROPOSAL_ID");
        require(_getProposalState(proposalId) == ProposalState.Succeeded, "VOTING_EXECUTION_STATE_ERROR");
        Proposal storage proposal = _proposals().proposalById[proposalId];
        require(!proposal.executed, "VOTING_EXECUTED_ERROR");
        // TODO: check that prev proposal was executed.
        proposal.executed = true;

        for (uint256 i; i < proposal.actionsLength; ++i) {
            ProposedAction memory action = _proposedAction().proposedActionbyIndex[proposalId][i];
            (bool didSucceed, ) = action.target.call{value: action.value}(action.data);
            require(didSucceed, "GOV_ACTION_EXECUTION_FAILED");
        }

        emit ProposalExecuted(proposalId);
    }

    /// @notice Casts a vote for the given proposal.
    /// @dev Only callable during the voting period for that proposal.
    function _castVote(address voter, uint256 proposalId, VoteType voteType) private {
        // TODO: check if necessary
        require(proposalId < _getProposalCount(), "VOTING_INVALID_ID_ERROR");

        Receipt memory receipt = _receipt().userReceiptByProposal[proposalId][voter];
        require(!receipt.hasVoted, "VOTING_ALREADY_VOTED_ERROR");

        // TODO: check if we use internal storage vs state methods
        Proposal storage proposal = _proposals().proposalById[proposalId];
        require(
            _getProposalState(proposalId) == ProposalState.Active,
            "VOTING_CLOSED_ERROR"
        );
        uint256 votingPower = _getVotingPower(voter);
        require(votingPower != 0, "VOTING_NO_VOTES_ERROR");

        if (voteType == VoteType.FOR) {
            proposal.votesFor += votingPower;
        } else if (voteType == VoteType.AGAINST) {
            proposal.votesAgainst += votingPower;
        } else if (voteType == VoteType.ABSTAIN) {
            proposal.votesAbstain += votingPower;
        } else {
            revert("UNKNOWN_SUPPORT_TYPE_ERROR");
        }

        _receipt().userReceiptByProposal[proposalId][voter] = Receipt({
            hasVoted: true,
            votes: uint96(votingPower),
            voteType: voteType
        });

        emit VoteCast(voter, proposalId, voteType, votingPower);
    }

    function _hasProposalPassed(Proposal memory proposal) internal view override returns (bool) {
        return IGovernanceStrategy(_governanceStrategy().value)
            .hasProposalPassed(proposal, _governanceParameters().quorumThreshold);
    }
}
