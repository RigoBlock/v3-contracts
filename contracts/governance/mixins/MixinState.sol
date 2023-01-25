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

abstract contract MixinState is MixinStorage, MixinAbstract {
    /// @inheritdoc IGovernanceState
    function getDeploymentConstants() external pure override returns (DeploymentConstants memory) {
        return DeploymentConstants({
            name: CONTRACT_NAME,
            symbol: CONTRACT_VERSION,
            proposalMaxOperations: PROPOSAL_MAX_OPERATIONS,
            domainTypehash: DOMAIN_TYPEHASH,
            voteTypehash: VOTE_TYPEHASH
        });
    }

    // TODO: check if we should name returned variables for docs
    /// @inheritdoc IGovernanceState
    function getProposalById(uint256 proposalId) public view override returns (Proposal memory, ProposedAction[] memory) {
        Proposal memory proposal = _proposals().value[proposalId];
        uint256 length = proposal.actionsLength;
        ProposedAction[] memory proposedActions = new ProposedAction[](length);

        for (uint i; i < length; i++) {
            proposedActions[i] = _proposedAction().proposedActionbyIndex[proposalId][length];
        }

        return (proposal, proposedActions);
    }

    /// @inheritdoc IGovernanceState
    function getProposalState(uint256 proposalId) public view override returns (ProposalState) {
        uint256 currentEpoch = IStorage(stakingProxy()).currentEpoch();
        Proposal storage proposal = _proposals().value[proposalId];
        if (currentEpoch < proposal.voteEpoch) {
            return ProposalState.Pending;
        } else if (currentEpoch == proposal.voteEpoch) {
            return ProposalState.Active;
        } else if (!_hasProposalPassed(proposal)) {
            return ProposalState.Defeated;
        } else if (proposal.executed) {
            return ProposalState.Executed;
        } else {
            return ProposalState.Succeeded;
        }
    }

    /// @inheritdoc IGovernanceState
    function getReceipt(uint256 proposalId, address voter)
        public
        view
        override
        returns (Receipt memory)
    {
        return _getReceipt(proposalId, voter);
    }

    function _getReceipt(uint256 proposalId, address voter)
        internal
        view
        override
        returns (Receipt memory)
    {
        return _receipt().value[proposalId][voter];
    }


    /// @inheritdoc IGovernanceState
    function getVotingPower(address account) public view override returns (uint256) {
        return _getVotingPower(account);
    }

    function _getVotingPower(address account) internal view override returns (uint256) {
        return
            IStaking(stakingProxy())
                .getOwnerStakeByStatus(account, IStructs.StakeStatus.DELEGATED)
                .currentEpochBalance;
    }

    /// @inheritdoc IGovernanceState
    function proposalCount() public view override returns (uint256 count) {
        return _getProposalCount();
    }

    function _getProposalCount() internal view override returns (uint256 count) {
        return _proposalCount().value;
    }

    /// @inheritdoc IGovernanceState
    function proposals() public view override returns (Proposal[] memory) {
        uint256 length = _getProposalCount();
        Proposal[] memory proposalList = new Proposal[](length);
        for (uint i; i < length; ++i) {
            proposalList[i] = _proposals().value[i];
        }
        return proposalList;
    }

    /// @inheritdoc IGovernanceState
    function stakingProxy() public view override returns (address) {
        return _getStakingProxy();
    }

    /// @inheritdoc IGovernanceState
    function treasuryParameters() public view override returns (TreasuryParameters memory) {
        return _getTreasuryParameters();
    }

    function _getStakingProxy() internal view override returns (address) {
        return _stakingProxy().value;
    }

    function _getTreasuryParameters() internal view override returns (TreasuryParameters memory) {
        return _paramsWrapper().treasuryParameters;
    }
}
