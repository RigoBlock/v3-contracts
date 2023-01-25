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

import "../../staking/interfaces/IStaking.sol";
import "../../staking/interfaces/IStorage.sol";
import "./MixinAbstract.sol";
import "./MixinStorage.sol";

abstract contract MixinVoting is MixinStorage, MixinAbstract {
    /// @inheritdoc IGovernanceVoting
    function propose(
        ProposedAction[] memory actions,
        uint256 executionEpoch,
        string memory description
    ) external override returns (uint256 proposalId) {
        uint256 length = actions.length;
        require(_getVotingPower(msg.sender) >= _treasuryParameters().proposalThreshold, "GOV_LOW_VOTING_POWER");
        require(length > 0, "GOV_NO_ACTIONS_ERROR");
        require(length <= PROPOSAL_MAX_OPERATIONS, "GOV_TOO_MANY_ACTIONS_ERROR");
        uint256 currentEpoch = IStorage(_getStakingProxy()).currentEpoch();
        require(executionEpoch >= currentEpoch + 2, "GOV_INVALID_EXECUTION_EPOCH");

        proposalId = _getProposalCount();
        //ProposedAction[] storage newActions = new ProposedAction[](2);
        Proposal memory newProposal = Proposal({
            actionsLength: length,
            executionEpoch: executionEpoch,
            voteEpoch: currentEpoch + 2,
            votesFor: 0,
            votesAgainst: 0,
            votesAbstain: 0,
            executed: false
        });

        for (uint i; i < length; i++) {
            _proposedAction().proposedActionbyIndex[proposalId][i] = actions[i];
        }

        _proposals().value[proposalId] = newProposal;
        ++_proposalCount().value;

        emit ProposalCreated(msg.sender, proposalId, actions, executionEpoch, description);
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
        if (proposalId >= _getProposalCount()) {
            revert("execute/INVALID_PROPOSAL_ID");
        }
        // TODO: read from state
        Proposal memory proposal = _proposals().value[proposalId];
        _assertProposalExecutable(proposal);

        _proposals().value[proposalId].executed = true;

        for (uint256 i = 0; i != proposal.actionsLength; i++) {
            ProposedAction memory action = _proposedAction().proposedActionbyIndex[proposalId][i];
            (bool didSucceed, ) = action.target.call{value: action.value}(action.data);
            require(didSucceed, "execute/ACTION_EXECUTION_FAILED");
        }

        emit ProposalExecuted(proposalId);
    }

    /// @notice Checks whether the given proposal has passed or not.
    /// @param proposal The proposal to check.
    /// @return hasPassed Whether the proposal has passed.
    function _hasProposalPassed(Proposal memory proposal) internal view override returns (bool hasPassed) {
        // Proposal is not passed until the vote is over.
        if (!_hasVoteEnded(proposal.voteEpoch)) {
            // Proposal is immediately executable if votes in favor higher than two thirds of total delegated GRG
            if (
                3 * proposal.votesFor >
                2 *
                    IStaking(_getStakingProxy())
                        .getGlobalStakeByStatus(IStructs.StakeStatus.DELEGATED)
                        .currentEpochBalance
            ) {
                return true;
            } else {
                return false;
            }
        }
        // Must have > 66.7% support.
        if (2 * proposal.votesFor <= proposal.votesAgainst) {
            return false;
        }
        // Must reach quorum threshold.
        if (proposal.votesFor < _treasuryParameters().quorumThreshold) {
            return false;
        }
        return true;
    }

    /// @notice Checks whether the given proposal is executable. Reverts if not.
    /// @param proposal The proposal to check.
    function _assertProposalExecutable(Proposal memory proposal) private view {
        require(_hasProposalPassed(proposal), "VOTING_NOT_PASSED_ERROR");
        require(!proposal.executed, "VOTING_EXECUTED_ERROR");
        require(
            IStorage(_getStakingProxy()).currentEpoch() == proposal.executionEpoch,
            "_VOTTING_EPOCH_ERROR"
        );
    }

    /// @notice Checks whether a vote starting at the given epoch has ended or not.
    /// @param voteEpoch The epoch at which the vote started.
    /// @return Boolean the vote has ended.
    function _hasVoteEnded(uint256 voteEpoch) private view returns (bool) {
        uint256 currentEpoch = IStorage(_getStakingProxy()).currentEpoch();
        if (currentEpoch < voteEpoch) {
            return false;
        }
        if (currentEpoch > voteEpoch) {
            return true;
        }
        // voteEpoch == currentEpoch
        // Vote ends at currentEpochStartTime + votingPeriod
        uint256 voteEndTime = IStorage(_getStakingProxy()).currentEpochStartTimeInSeconds() +
            _treasuryParameters().votingPeriod;
        return block.timestamp > voteEndTime;
    }

    /// @notice Casts a vote for the given proposal.
    /// @dev Only callable during the voting period for that proposa.
    function _castVote(address voter, uint256 proposalId, VoteType voteType) private {
        if (proposalId >= _getProposalCount()) {
            revert("_castVote/INVALID_PROPOSAL_ID");
        }
        if (_getReceipt(proposalId, voter).hasVoted) {
            revert("_castVote/ALREADY_VOTED");
        }

        Proposal memory proposal = _proposals().value[proposalId];
        if (proposal.voteEpoch != IStorage(_getStakingProxy()).currentEpoch() || _hasVoteEnded(proposal.voteEpoch)) {
            revert("_castVote/VOTING_IS_CLOSED");
        }

        uint256 votingPower = _getVotingPower(voter);
        if (votingPower == 0) {
            revert("_castVote/NO_VOTING_POWER");
        }

        if (voteType == VoteType.FOR) {
            _proposals().value[proposalId].votesFor += votingPower;
        } else if (voteType == VoteType.AGAINST) {
            _proposals().value[proposalId].votesAgainst += votingPower;
        } else if (voteType == VoteType.ABSTAIN) {
            _proposals().value[proposalId].votesAbstain += votingPower;
        } else {
            revert("UNKNOWN_SUPPORT_TYPE_ERROR");
        }

        _receipt().value[proposalId][voter].hasVoted = true;

        emit VoteCast(voter, proposalId, voteType, votingPower);
    }
}
