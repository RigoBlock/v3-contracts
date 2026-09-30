// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {ProposalStatus} from "../types/GovernanceTypes.sol";
import {IGovernanceState} from "../interfaces/governance/IGovernanceState.sol";
import {IGovernanceStrategy} from "../interfaces/IGovernanceStrategy.sol";
import {IGovernanceVoting} from "../interfaces/governance/IGovernanceVoting.sol";
import {Governor} from "@openzeppelin-gov/governance/Governor.sol";
import {IGovernor as IOZGovernor} from "@openzeppelin-gov/governance/IGovernor.sol";
import {IERC165} from "@openzeppelin-gov/utils/introspection/IERC165.sol";
import {IERC5267} from "@openzeppelin-gov/interfaces/IERC5267.sol";
import {IERC6372} from "@openzeppelin-gov/interfaces/IERC6372.sol";
import {MixinAbstract} from "./MixinAbstract.sol";
import {MixinStorage} from "./MixinStorage.sol";

abstract contract MixinState is Governor, MixinStorage, MixinAbstract {
    /// @inheritdoc IGovernanceState
    function getActions(
        uint256 proposalId
    ) external view override returns (IGovernanceVoting.ProposedAction[] memory proposedActions) {
        IGovernanceState.Proposal memory proposal = _proposal().proposalById[proposalId];
        uint256 actionsLength = proposal.actionsLength;
        proposedActions = new IGovernanceVoting.ProposedAction[](actionsLength);
        for (uint256 i = 0; i < actionsLength; i++) {
            proposedActions[i] = _proposedAction().proposedActionbyIndex[proposalId][i];
        }
    }

    /// @inheritdoc IGovernanceState
    function getProposalState(uint256 proposalId) external view override returns (ProposalStatus) {
        return _getProposalState(proposalId);
    }

    /// @inheritdoc IGovernanceState
    function getReceipt(
        uint256 proposalId,
        address voter
    ) external view override returns (IGovernanceState.Receipt memory) {
        return _receipt().userReceiptByProposal[proposalId][voter];
    }

    /// @inheritdoc IGovernanceState
    function getVotingPower(address account) external view override returns (uint256) {
        return _getVotingPower(account);
    }

    /// @inheritdoc IGovernanceState
    function governanceParameters() external view override returns (IGovernanceState.EnhancedParams memory) {
        return
            IGovernanceState.EnhancedParams({
                params: _paramsWrapper().governanceParameters,
                name: _name().value,
                version: VERSION
            });
    }

    /// @inheritdoc IOZGovernor
    function name() public view override(Governor, IOZGovernor) returns (string memory) {
        return _name().value;
    }

    /// @inheritdoc IGovernanceState
    function proposalCount() external view override returns (uint256 count) {
        return _getProposalCount();
    }

    /// @inheritdoc IGovernanceState
    function proposer(uint256 proposalId) external view override returns (address proposer) {
        return _proposalMeta().proposalMetaById[proposalId].proposer;
    }

    /// @inheritdoc IGovernanceState
    function canceled(uint256 proposalId) external view override returns (bool canceled) {
        return _proposalMeta().proposalMetaById[proposalId].canceled;
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

    /// @inheritdoc IOZGovernor
    function votingPeriod() public view override(Governor, IOZGovernor) returns (uint256) {
        return IGovernanceStrategy(_governanceParameters().strategy).votingPeriod();
    }

    /// @inheritdoc IERC6372
    function CLOCK_MODE() public pure override(Governor, IERC6372) returns (string memory) {
        return "mode=timestamp";
    }

    /// @inheritdoc IERC6372
    function clock() public view override(Governor, IERC6372) returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override(Governor, IERC165) returns (bool) {
        return
            interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IOZGovernor).interfaceId ||
            interfaceId == type(IERC6372).interfaceId ||
            interfaceId == type(IERC5267).interfaceId;
    }

    /// @inheritdoc IOZGovernor
    function COUNTING_MODE() public pure override returns (string memory) {
        return "support=bravo&quorum=bravo";
    }

    /// @inheritdoc IOZGovernor
    function hashProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public pure override(Governor, IOZGovernor) returns (uint256) {
        return _hashProposal(targets, values, calldatas, descriptionHash);
    }

    /// @inheritdoc IOZGovernor
    function getProposalId(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public view override(Governor, IOZGovernor) returns (uint256) {
        return hashProposal(targets, values, calldatas, descriptionHash);
    }

    /// @inheritdoc IOZGovernor
    function proposalProposer(uint256 proposalId) public view override(Governor, IOZGovernor) returns (address) {
        return _proposalMeta().proposalMetaById[proposalId].proposer;
    }

    /// @inheritdoc IOZGovernor
    function proposalEta(uint256) public pure override(Governor, IOZGovernor) returns (uint256) {
        return 0; // no timelock
    }

    /// @inheritdoc IOZGovernor
    function proposalNeedsQueuing(uint256) public pure override(Governor, IOZGovernor) returns (bool) {
        return false; // no timelock
    }

    /// @inheritdoc IOZGovernor
    /// @dev Must not call super: OZ Governor linear storage (slots 0-6) must stay empty. See docs/governance/TALLY_COMPAT.md.
    function state(uint256 proposalId) public view override(Governor, IOZGovernor) returns (IOZGovernor.ProposalState) {
        return _toOZState(_getProposalState(proposalId));
    }

    /// @dev Translates the native state into the OZ Governor numbering: Qualified maps to
    ///      Succeeded, higher native values shift down one position. See docs/governance/TALLY_COMPAT.md.
    function _toOZState(ProposalStatus proposalState) private pure returns (IOZGovernor.ProposalState) {
        uint8 value = uint8(proposalState);
        if (value == uint8(ProposalStatus.Qualified)) {
            return IOZGovernor.ProposalState.Succeeded;
        }
        return IOZGovernor.ProposalState(value > uint8(ProposalStatus.Canceled) ? value - 1 : value);
    }

    /// @inheritdoc IOZGovernor
    function votingDelay() public pure override(Governor, IOZGovernor) returns (uint256) {
        // voting starts at least one second in the future (see votingTimestamps)
        return 1;
    }

    /// @inheritdoc IOZGovernor
    function proposalSnapshot(uint256 proposalId) public view override(Governor, IOZGovernor) returns (uint256) {
        return _proposal().proposalById[proposalId].startBlockOrTime;
    }

    /// @inheritdoc IOZGovernor
    function proposalDeadline(uint256 proposalId) public view override(Governor, IOZGovernor) returns (uint256) {
        return _proposal().proposalById[proposalId].endBlockOrTime;
    }

    /// @inheritdoc IOZGovernor
    function proposalThreshold() public view override(Governor, IOZGovernor) returns (uint256) {
        return _governanceParameters().proposalThreshold;
    }

    /// @inheritdoc IOZGovernor
    function quorum(uint256) public view override(Governor, IOZGovernor) returns (uint256) {
        return _governanceParameters().quorumThreshold;
    }

    /// @inheritdoc IOZGovernor
    function hasVoted(uint256 proposalId, address account) public view override returns (bool) {
        return _receipt().userReceiptByProposal[proposalId][account].hasVoted;
    }

    /// @inheritdoc IGovernanceState
    function proposalVotes(
        uint256 proposalId
    ) external view override returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) {
        IGovernanceState.Proposal memory proposal = _proposal().proposalById[proposalId];
        return (proposal.votesAgainst, proposal.votesFor, proposal.votesAbstain);
    }

    /// @inheritdoc IOZGovernor
    function version() public view override(Governor, IOZGovernor) returns (string memory) {
        return VERSION;
    }

    /// @inheritdoc IGovernanceState
    function getProposalById(
        uint256 proposalId
    ) public view override returns (IGovernanceState.ProposalWrapper memory proposalWrapper) {
        proposalWrapper.proposal = _proposal().proposalById[proposalId];
        uint256 actionsLength = proposalWrapper.proposal.actionsLength;
        IGovernanceVoting.ProposedAction[] memory proposedAction = new IGovernanceVoting.ProposedAction[](
            actionsLength
        );
        for (uint256 i = 0; i < actionsLength; i++) {
            proposedAction[i] = _proposedAction().proposedActionbyIndex[proposalId][i];
        }
        proposalWrapper.proposedAction = proposedAction;
    }

    function _getProposalCount() internal view override returns (uint256 count) {
        return _proposalCount().value;
    }

    function _getProposalState(uint256 proposalId) internal view override returns (ProposalStatus) {
        require(_proposalCount().value >= proposalId && proposalId != 0, GovProposalIdInvalid(proposalId));
        IGovernanceState.Proposal memory proposal = _proposal().proposalById[proposalId];

        if (_proposalMeta().proposalMetaById[proposalId].canceled) {
            return ProposalStatus.Canceled;
        }

        // prevent old-format proposals execution if quorum drops
        uint256 quorum = _proposalQuorum().proposalQuorumById[proposalId];
        quorum = quorum > 0 ? quorum : type(uint256).max;

        return
            IGovernanceStrategy(_governanceParameters().strategy).getProposalState(
                proposal,
                quorum,
                _governanceParameters().timeType
            );
    }

    function _getVotingPower(address account) internal view override returns (uint256) {
        return IGovernanceStrategy(_governanceParameters().strategy).getVotingPower(account);
    }
}
