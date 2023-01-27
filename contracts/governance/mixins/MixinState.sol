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

abstract contract MixinState is MixinStorage, MixinAbstract {
    // TODO: check where we are using this and whether it is correct naming.
    /// @inheritdoc IGovernanceState
    function getDeploymentConstants() external view override returns (DeploymentConstants memory) {
        return DeploymentConstants({
            name: name(),
            version: VERSION,
            proposalMaxOperations: PROPOSAL_MAX_OPERATIONS,
            domainTypehash: DOMAIN_TYPEHASH,
            voteTypehash: VOTE_TYPEHASH
        });
    }

    // TODO: check if we should name returned variables for docs
    /// @inheritdoc IGovernanceState
    function getProposalById(uint256 proposalId) public view override returns (Proposal memory, ProposedAction[] memory) {
        Proposal memory proposal = _proposals().proposalById[proposalId];
        uint256 length = proposal.actionsLength;
        ProposedAction[] memory proposedActions = new ProposedAction[](length);

        for (uint i; i < length; i++) {
            proposedActions[i] = _proposedAction().proposedActionbyIndex[proposalId][length];
        }

        return (proposal, proposedActions);
    }

    /// @inheritdoc IGovernanceState
    function getProposalState(uint256 proposalId) public view override returns (ProposalState) {
        return getProposalState(proposalId);
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

    /// @inheritdoc IGovernanceState
    function getVotingPower(address account) external view override returns (uint256) {
        return _getVotingPower(account);
    }

    /// @inheritdoc IGovernanceState
    function governanceParameters() public view override returns (GovernanceParameters memory) {
        return _getGovernanceParameters();
    }

    /// @inheritdoc IGovernanceState
    function governanceStrategy() public view override returns (address) {
        return _governanceStrategy().value;
    }

    /// @inheritdoc IGovernanceState
    function name() public view override returns (string memory) {
        return _name().value;
    }

    /// @inheritdoc IGovernanceState
    function proposalCount() public view override returns (uint256 count) {
        return _getProposalCount();
    }

    /// @inheritdoc IGovernanceState
    function proposals() public view override returns (Proposal[] memory) {
        uint256 length = _getProposalCount();
        Proposal[] memory proposalList = new Proposal[](length);
        for (uint i; i < length; ++i) {
            proposalList[i] = _proposals().proposalById[i];
        }
        return proposalList;
    }

    function _getGovernanceParameters() internal view override returns (GovernanceParameters memory) {
        return _paramsWrapper().governanceParameters;
    }

    function _getProposalCount() internal view override returns (uint256 count) {
        return _proposalCount().value;
    }

    function _getProposalState(uint256 proposalId) internal view override returns (ProposalState) {
        require(_proposalCount().value >= proposalId, "VOTING_PROPOSAL_ID_ERROR");
        Proposal memory proposal = _proposals().proposalById[proposalId];
        if (block.timestamp <= proposal.startTime) {
            return ProposalState.Pending;
        } else if (block.timestamp < proposal.endTime) {
            return ProposalState.Active;
        } else if (!_hasProposalPassed(proposal)) {
            return ProposalState.Defeated;
        } else if (proposal.executed) {
            return ProposalState.Executed;
        } else {
            return ProposalState.Succeeded;
        }
    }

    function _getReceipt(uint256 proposalId, address voter)
        internal
        view
        override
        returns (Receipt memory)
    {
        return _receipt().userReceiptByProposal[proposalId][voter];
    }

    function _getVotingPower(address account) internal view override returns (uint256) {
        return IGovernanceStrategy(_governanceStrategy().value).getVotingPower(account);
    }
}
