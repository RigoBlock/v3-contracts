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
import "./MixinStorage.sol";

abstract contract MixinVoting is MixinStorage {
    /// @inheritdoc IRigoblockGovernance
    function propose(
        ProposedAction[] memory actions,
        uint256 executionEpoch,
        string memory description
    ) external override returns (uint256 proposalId) {
        require(getVotingPower(msg.sender) >= treasuryParameters().proposalThreshold, "GOV_LOW_VOTING_POWER");
        require(actions.length > 0, "GOV_NO_ACTIONS_ERROR");
        uint256 currentEpoch = IStorage(getStakingProxy()).currentEpoch();
        require(executionEpoch >= currentEpoch + 2, "GOV_INVALID_EXECUTION_EPOCH");

        // TODO: fix style
        proposalId = proposalCount();
        proposals().value[proposalsCount().value] = Proposal({
            actionsHash: keccak256(abi.encode(actions)),
            executionEpoch: executionEpoch,
            voteEpoch: currentEpoch + 2,
            votesFor: 0,
            votesAgainst: 0,
            votesAbstain: 0,
            executed: false
        });
        ++proposalsCount().value;

        emit ProposalCreated(msg.sender, proposalId, actions, executionEpoch, description);
    }

    /// @inheritdoc IRigoblockGovernance
    function castVote(uint256 proposalId, VoteType voteType) external override {
        return _castVote(msg.sender, proposalId, voteType);
    }

    /// @inheritdoc IRigoblockGovernance
    function castVoteBySignature(
        uint256 proposalId,
        VoteType voteType,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        bytes32 structHash = keccak256(abi.encode(VOTE_TYPEHASH, proposalId, voteType));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator().value, structHash));
        address signatory = ecrecover(digest, v, r, s);

        return _castVote(signatory, proposalId, voteType);
    }

    /// @inheritdoc IRigoblockGovernance
    function execute(uint256 proposalId, ProposedAction[] memory actions) external payable override {
        if (proposalId >= proposalCount()) {
            revert("execute/INVALID_PROPOSAL_ID");
        }
        Proposal memory proposal = proposals().value[proposalId];
        _assertProposalExecutable(proposal, actions);

        proposals().value[proposalId].executed = true;

        for (uint256 i = 0; i != actions.length; i++) {
            ProposedAction memory action = actions[i];
            (bool didSucceed, ) = action.target.call{value: action.value}(action.data);
            require(didSucceed, "execute/ACTION_EXECUTION_FAILED");
        }

        emit ProposalExecuted(proposalId);
    }

    /// @inheritdoc IRigoblockGovernance
    function proposalCount()
        public
        view
        override
        returns (uint256 count)
    {
        return proposalsCount().value;
    }

    /// @inheritdoc IRigoblockGovernance
    function getVotingPower(address account)
        public
        view
        override
        returns (uint256)
    {
        return IStaking(getStakingProxy())
            .getOwnerStakeByStatus(account, IStructs.StakeStatus.DELEGATED)
            .currentEpochBalance;
    }

    /// @notice Checks whether the given proposal is executable. Reverts if not.
    /// @param proposal The proposal to check.
    function _assertProposalExecutable(Proposal memory proposal, ProposedAction[] memory actions) private view {
        require(keccak256(abi.encode(actions)) == proposal.actionsHash, "_assertProposalExecutable/INVALID_ACTIONS");
        require(_hasProposalPassed(proposal), "_assertProposalExecutable/PROPOSAL_HAS_NOT_PASSED");
        require(!proposal.executed, "_assertProposalExecutable/PROPOSAL_ALREADY_EXECUTED");
        require(
            IStorage(getStakingProxy()).currentEpoch() == proposal.executionEpoch,
            "_assertProposalExecutable/CANNOT_EXECUTE_THIS_EPOCH"
        );
    }

    /// @notice Checks whether the given proposal has passed or not.
    /// @param proposal The proposal to check.
    /// @return hasPassed Whether the proposal has passed.
    function _hasProposalPassed(Proposal memory proposal) private view returns (bool hasPassed) {
        // Proposal is not passed until the vote is over.
        if (!_hasVoteEnded(proposal.voteEpoch)) {
            // TODO: proposal immediately executable if supported by majority of active staked GRG (or staked GRG, which is even bigger)
            return false;
        }
        // Must have >50% support.
        if (proposal.votesFor <= proposal.votesAgainst) {
            return false;
        }
        // Must reach quorum threshold.
        if (proposal.votesFor < treasuryParameters().quorumThreshold) {
            return false;
        }
        return true;
    }

    /// @notice Checks whether a vote starting at the given epoch has ended or not.
    /// @param voteEpoch The epoch at which the vote started.
    /// @return Boolean the vote has ended.
    function _hasVoteEnded(uint256 voteEpoch) private view returns (bool) {
        uint256 currentEpoch = IStorage(getStakingProxy()).currentEpoch();
        if (currentEpoch < voteEpoch) {
            return false;
        }
        if (currentEpoch > voteEpoch) {
            return true;
        }
        // voteEpoch == currentEpoch
        // Vote ends at currentEpochStartTime + votingPeriod
        uint256 voteEndTime = IStorage(getStakingProxy()).currentEpochStartTimeInSeconds() + treasuryParameters().votingPeriod;
        return block.timestamp > voteEndTime;
    }

    /// @notice Casts a vote for the given proposal.
    /// @dev Only callable during the voting period for that proposa.
    function _castVote(address voter, uint256 proposalId, VoteType voteType) private {
        if (proposalId >= proposalCount()) {
            revert("_castVote/INVALID_PROPOSAL_ID");
        }
        if (hasVoted().value[proposalId][voter]) {
            revert("_castVote/ALREADY_VOTED");
        }

        Proposal memory proposal = proposals().value[proposalId];
        if (proposal.voteEpoch != IStorage(getStakingProxy()).currentEpoch() || _hasVoteEnded(proposal.voteEpoch)) {
            revert("_castVote/VOTING_IS_CLOSED");
        }

        uint256 votingPower = getVotingPower(voter);
        if (votingPower == 0) {
            revert("_castVote/NO_VOTING_POWER");
        }

        if (voteType == VoteType.FOR) {
            proposals().value[proposalId].votesFor += votingPower;
        } else if (voteType == VoteType.AGAINST) {
            proposals().value[proposalId].votesAgainst += votingPower;
        } else if (voteType == VoteType.ABSTAIN) {
            proposals().value[proposalId].votesAbstain += votingPower;
        } else { revert("UNKNOWN_SUPPORT_TYPE_ERROR"); }

        hasVoted().value[proposalId][voter] = true;

        emit VoteCast(voter, proposalId, voteType, votingPower);
    }
}