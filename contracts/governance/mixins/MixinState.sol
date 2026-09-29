// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {IGovernanceState} from "../interfaces/governance/IGovernanceState.sol";
import {IGovernanceStrategy} from "../interfaces/IGovernanceStrategy.sol";
import {IGovernanceVoting} from "../interfaces/governance/IGovernanceVoting.sol";
import {IGovernor as IOZGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC6372} from "@openzeppelin-legacy/contracts/interfaces/IERC6372.sol";
import {MixinAbstract} from "./MixinAbstract.sol";
import {MixinStorage} from "./MixinStorage.sol";

abstract contract MixinState is MixinStorage, MixinAbstract {
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
    function getProposalState(uint256 proposalId) external view override returns (IGovernanceState.ProposalStatus) {
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
    function name() public view override returns (string memory) {
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
    function votingPeriod() public view override returns (uint256) {
        return IGovernanceStrategy(_governanceParameters().strategy).votingPeriod();
    }

    /// @inheritdoc IERC6372
    function CLOCK_MODE() external pure override returns (string memory) {
        return "mode=timestamp";
    }

    /// @inheritdoc IERC6372
    function clock() external view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return
            interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IOZGovernor).interfaceId ||
            interfaceId == type(IERC6372).interfaceId;
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
    ) public pure override returns (uint256) {
        return uint256(keccak256(abi.encode(targets, values, calldatas, descriptionHash)));
    }

    /// @inheritdoc IOZGovernor
    function state(uint256 proposalId) public view override returns (IOZGovernor.ProposalState) {
        return _toOZState(_getProposalState(proposalId));
    }

    /// @dev Translates the native state into the OZ Governor numbering: Qualified maps to
    ///      Succeeded, higher native values shift down one position. See docs/governance/TALLY_COMPAT.md.
    function _toOZState(
        IGovernanceState.ProposalStatus proposalState
    ) private pure returns (IOZGovernor.ProposalState) {
        uint8 value = uint8(proposalState);
        if (value == uint8(IGovernanceState.ProposalStatus.Qualified)) {
            return IOZGovernor.ProposalState.Succeeded;
        }
        return IOZGovernor.ProposalState(value > uint8(IGovernanceState.ProposalStatus.Canceled) ? value - 1 : value);
    }

    /// @inheritdoc IOZGovernor
    function votingDelay() public pure override returns (uint256) {
        // voting starts at least one second in the future (see votingTimestamps)
        return 1;
    }

    /// @inheritdoc IOZGovernor
    function proposalSnapshot(uint256 proposalId) public view override returns (uint256) {
        return _proposal().proposalById[proposalId].startBlockOrTime;
    }

    /// @inheritdoc IOZGovernor
    function proposalDeadline(uint256 proposalId) public view override returns (uint256) {
        return _proposal().proposalById[proposalId].endBlockOrTime;
    }

    /// @inheritdoc IGovernanceState
    function proposalThreshold() public view override returns (uint256) {
        return _governanceParameters().proposalThreshold;
    }

    /// @inheritdoc IOZGovernor
    function quorum(uint256) public view override returns (uint256) {
        return _governanceParameters().quorumThreshold;
    }

    /// @inheritdoc IOZGovernor
    function getVotes(address account, uint256) public view override returns (uint256) {
        return _getVotingPower(account);
    }

    /// @inheritdoc IOZGovernor
    function getVotesWithParams(address account, uint256, bytes memory) public view override returns (uint256) {
        return _getVotingPower(account);
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
    function version() public view override returns (string memory) {
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

    function _getProposalState(uint256 proposalId) internal view override returns (IGovernanceState.ProposalStatus) {
        require(_proposalCount().value >= proposalId && proposalId != 0, GovProposalIdInvalid(proposalId));
        IGovernanceState.Proposal memory proposal = _proposal().proposalById[proposalId];

        if (_proposalMeta().proposalMetaById[proposalId].canceled) {
            return IGovernanceState.ProposalStatus.Canceled;
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
