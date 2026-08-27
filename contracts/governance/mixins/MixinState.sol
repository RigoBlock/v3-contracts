// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {IGovernanceState} from "../interfaces/governance/IGovernanceState.sol";
import {IGovernanceStrategy} from "../interfaces/IGovernanceStrategy.sol";
import {IGovernanceVoting} from "../interfaces/governance/IGovernanceVoting.sol";
import {MixinAbstract} from "./MixinAbstract.sol";
import {MixinStorage} from "./MixinStorage.sol";

abstract contract MixinState is MixinStorage, MixinAbstract {
    /// @inheritdoc IGovernanceState
    function getActions(uint256 proposalId) external view override returns (IGovernanceVoting.ProposedAction[] memory proposedActions) {
        IGovernanceState.Proposal memory proposal = _proposal().proposalById[proposalId];
        uint256 actionsLength = proposal.actionsLength;
        proposedActions = new IGovernanceVoting.ProposedAction[](actionsLength);
        for (uint256 i = 0; i < actionsLength; i++) {
            proposedActions[i] = _proposedAction().proposedActionbyIndex[proposalId][i];
        }
    }

    /// @inheritdoc IGovernanceState
    function getProposalState(uint256 proposalId) external view override returns (IGovernanceState.ProposalState) {
        return _getProposalState(proposalId);
    }

    /// @inheritdoc IGovernanceState
    function getReceipt(uint256 proposalId, address voter) external view override returns (IGovernanceState.Receipt memory) {
        return _receipt().userReceiptByProposal[proposalId][voter];
    }

    /// @inheritdoc IGovernanceState
    function getVotingPower(address account) external view override returns (uint256) {
        return _getVotingPower(account);
    }

    /// @inheritdoc IGovernanceState
    function governanceParameters() external view override returns (IGovernanceState.EnhancedParams memory) {
        return IGovernanceState.EnhancedParams({params: _paramsWrapper().governanceParameters, name: _name().value, version: VERSION});
    }

    /// @inheritdoc IGovernanceState
    function name() external view override returns (string memory) {
        return _name().value;
    }

    /// @inheritdoc IGovernanceState
    function proposalCount() external view override returns (uint256 count) {
        return _getProposalCount();
    }

    /// @inheritdoc IGovernanceState
    function proposals() external view override returns (IGovernanceState.ProposalWrapper[] memory proposalWrapper) {
        uint256 length = _getProposalCount();
        proposalWrapper = new IGovernanceState.ProposalWrapper[](length);
        for (uint256 i = 0; i < length; i++) {
            // proposal count starts at proposalId = 1
            proposalWrapper[i] = getProposalById(i + 1);
        }
    }

    /// @inheritdoc IGovernanceState
    function votingPeriod() external view override returns (uint256) {
        return IGovernanceStrategy(_governanceParameters().strategy).votingPeriod();
    }

    /// @inheritdoc IGovernanceState
    function getProposalById(uint256 proposalId) public view override returns (IGovernanceState.ProposalWrapper memory proposalWrapper) {
        proposalWrapper.proposal = _proposal().proposalById[proposalId];
        uint256 actionsLength = proposalWrapper.proposal.actionsLength;
        IGovernanceVoting.ProposedAction[] memory proposedAction = new IGovernanceVoting.ProposedAction[](actionsLength);
        for (uint256 i = 0; i < actionsLength; i++) {
            proposedAction[i] = _proposedAction().proposedActionbyIndex[proposalId][i];
        }
        proposalWrapper.proposedAction = proposedAction;
    }

    function _getProposalCount() internal view override returns (uint256 count) {
        return _proposalCount().value;
    }

    function _getProposalState(uint256 proposalId) internal view override returns (IGovernanceState.ProposalState) {
        require(_proposalCount().value >= proposalId && proposalId != 0, GovProposalIdInvalid(proposalId));
        IGovernanceState.Proposal memory proposal = _proposal().proposalById[proposalId];

        // prevent old-format proposals execution if quorum drops
        uint256 quorum = _proposalQuorum().proposalQuorumById[proposalId];
        quorum = quorum > 0 ? quorum : type(uint256).max;

        return IGovernanceStrategy(_governanceParameters().strategy).getProposalState(proposal, quorum);
    }

    function _getVotingPower(address account) internal view override returns (uint256) {
        return IGovernanceStrategy(_governanceParameters().strategy).getVotingPower(account);
    }
}
