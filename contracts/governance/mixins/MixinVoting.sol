// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {IGovernanceState} from "../interfaces/governance/IGovernanceState.sol";
import {IGovernanceVoting} from "../interfaces/governance/IGovernanceVoting.sol";
import {IGovernanceStrategy} from "../interfaces/IGovernanceStrategy.sol";
import {IGovernor as IOZGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {TimeType} from "../types/TimeType.sol";
import {MixinAbstract} from "./MixinAbstract.sol";
import {MixinStorage} from "./MixinStorage.sol";
import {GovernanceActionLib} from "../libraries/GovernanceActionLib.sol";

abstract contract MixinVoting is MixinStorage, MixinAbstract {
    /// @notice Thrown when the proposer has insufficient voting power.
    /// @param votingPower The proposer's current voting power.
    /// @param proposalThreshold The minimum voting power required to propose.
    error GovLowVotingPower(uint256 votingPower, uint256 proposalThreshold);

    /// @notice Thrown when a proposal contains no actions.
    error GovNoActions();

    /// @notice Thrown when a proposal contains too many actions.
    /// @param provided The number of actions submitted.
    /// @param max The maximum number of actions allowed per proposal.
    error GovTooManyActions(uint256 provided, uint256 max);

    /// @notice Thrown when a vote is cast outside the active voting period.
    /// @param proposalId The id of the proposal.
    /// @param state The current state of the proposal.
    error GovVotingClosed(uint256 proposalId, IGovernanceState.ProposalStatus state);

    /// @notice Thrown when a voter tries to vote twice on the same proposal.
    /// @param proposalId The id of the proposal.
    /// @param voter The address that has already voted.
    error GovAlreadyVoted(uint256 proposalId, address voter);

    /// @notice Thrown when a voter has no voting power.
    /// @param voter The address that attempted to vote.
    error GovNoVotes(address voter);

    /// @notice Thrown when `execute` is called with insufficient native tokens.
    /// @param required The amount required for execution.
    /// @param provided The amount of native tokens sent with the call.
    error GovExecutionValueMismatch(uint256 required, uint256 provided);

    /// @notice Thrown when an account other than the proposer tries to cancel a proposal.
    /// @param proposalId The id of the proposal.
    /// @param caller The account that attempted the cancellation.
    error GovUnableToCancel(uint256 proposalId, address caller);

    /// @notice Thrown when the OZ-format propose receives arrays of different lengths.
    error GovActionsLengthMismatch();

    /// @notice Thrown when a vote is cast with a support value that is not a valid vote type.
    /// @param support The supplied support value.
    error GovInvalidSupport(uint8 support);

    /// @notice Thrown when the OZ-format execute does not match any stored proposal.
    /// @param proposalHash The OpenZeppelin proposal hash computed from the supplied arguments.
    error GovProposalIdUnknown(bytes32 proposalHash);

    /// @notice Thrown when a vote signature does not recover to a valid signatory.
    error GovInvalidSignature();

    /// @inheritdoc IGovernanceVoting
    function propose(
        IGovernanceVoting.ProposedAction[] memory actions,
        string memory description
    ) external override returns (uint256 proposalId) {
        proposalId = _propose(actions, description);
    }

    /// @inheritdoc IOZGovernor
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override returns (uint256 proposalId) {
        uint256 targetsLength = targets.length;
        require(targetsLength == values.length && targetsLength == calldatas.length, GovActionsLengthMismatch());
        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](targetsLength);
        for (uint256 i = 0; i < targetsLength; i++) {
            actions[i] = IGovernanceVoting.ProposedAction({target: targets[i], data: calldatas[i], value: values[i]});
        }
        proposalId = _propose(actions, description);
    }

    function _propose(
        IGovernanceVoting.ProposedAction[] memory actions,
        string memory description
    ) internal returns (uint256 proposalId) {
        uint256 length = actions.length;
        uint256 proposalThreshold = _governanceParameters().proposalThreshold;
        require(
            _getVotingPower(msg.sender) >= proposalThreshold,
            GovLowVotingPower(_getVotingPower(msg.sender), proposalThreshold)
        );
        require(length > 0, GovNoActions());
        require(length <= PROPOSAL_MAX_OPERATIONS, GovTooManyActions(length, PROPOSAL_MAX_OPERATIONS));

        address strategy = _governanceParameters().strategy;
        (uint256 startBlockOrTime, uint256 endBlockOrTime) = IGovernanceStrategy(strategy).votingTimestamps(
            _governanceParameters().timeType
        );

        // proposals start from id = 1
        _proposalCount().value++;
        proposalId = _getProposalCount();
        _proposalMeta().proposalMetaById[proposalId].proposer = msg.sender;
        IGovernanceState.Proposal memory newProposal = IGovernanceState.Proposal({
            actionsLength: length,
            startBlockOrTime: startBlockOrTime,
            endBlockOrTime: endBlockOrTime,
            votesFor: 0,
            votesAgainst: 0,
            votesAbstain: 0,
            executed: false
        });

        // Validate and optionally modify each action through the strategy before storing.
        for (uint256 i = 0; i < length; i++) {
            actions[i] = IGovernanceStrategy(strategy).beforePropose(actions[i]);
            _proposedAction().proposedActionbyIndex[proposalId][i] = actions[i];
        }

        _proposal().proposalById[proposalId] = newProposal;
        _proposalQuorum().proposalQuorumById[proposalId] = _governanceParameters().quorumThreshold;

        emit ProposalCreated(msg.sender, proposalId, actions, startBlockOrTime, endBlockOrTime, description);
        _mapOzHashAndEmitOZProposalCreated(proposalId, actions, startBlockOrTime, endBlockOrTime, description);
    }

    /// @dev Maps the OpenZeppelin proposal hash to the sequential id (so the OZ execute flow
    ///      resolves to the stored proposal) and emits the OZ-format ProposalCreated event.
    function _mapOzHashAndEmitOZProposalCreated(
        uint256 proposalId,
        IGovernanceVoting.ProposedAction[] memory actions,
        uint256 startBlockOrTime,
        uint256 endBlockOrTime,
        string memory description
    ) internal {
        uint256 length = actions.length;
        address[] memory targets = new address[](length);
        uint256[] memory values = new uint256[](length);
        bytes[] memory calldatas = new bytes[](length);
        for (uint256 i = 0; i < length; i++) {
            targets[i] = actions[i].target;
            values[i] = actions[i].value;
            calldatas[i] = actions[i].data;
        }
        _ozProposalIds().idByHash[
            bytes32(hashProposal(targets, values, calldatas, keccak256(bytes(description))))
        ] = proposalId;
        emit IOZGovernor.ProposalCreated(
            proposalId,
            msg.sender,
            targets,
            values,
            new string[](length),
            calldatas,
            startBlockOrTime,
            endBlockOrTime,
            description
        );
    }

    /// @inheritdoc IOZGovernor
    function castVote(uint256 proposalId, uint8 support) public override returns (uint256 weight) {
        weight = _castVote(msg.sender, proposalId, _toVoteType(support), "");
    }

    /// @inheritdoc IOZGovernor
    function castVoteWithReason(
        uint256 proposalId,
        uint8 support,
        string calldata reason
    ) public override returns (uint256 weight) {
        weight = _castVote(msg.sender, proposalId, _toVoteType(support), reason);
    }

    /// @inheritdoc IOZGovernor
    function castVoteWithReasonAndParams(
        uint256 proposalId,
        uint8 support,
        string calldata reason,
        bytes memory params
    ) public override returns (uint256 weight) {
        IGovernanceVoting.VoteType voteType = _toVoteType(support);
        weight = _castVote(msg.sender, proposalId, voteType, reason);
        if (params.length != 0) {
            uint256 votingPower = weight;
            emit IOZGovernor.VoteCastWithParams(msg.sender, proposalId, support, votingPower, reason, params);
        }
    }

    /// @inheritdoc IOZGovernor
    function castVoteBySig(
        uint256 proposalId,
        uint8 support,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public override returns (uint256 weight) {
        weight = _castVoteBySig(proposalId, _toVoteType(support), "", v, r, s);
    }

    /// @inheritdoc IOZGovernor
    function castVoteWithReasonAndParamsBySig(
        uint256 proposalId,
        uint8 support,
        string calldata reason,
        bytes memory params,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public override returns (uint256 weight) {
        weight = _castVoteBySig(proposalId, _toVoteType(support), reason, v, r, s);
        if (params.length != 0) {
            uint256 votingPower = weight;
            emit IOZGovernor.VoteCastWithParams(msg.sender, proposalId, support, votingPower, reason, params);
        }
    }

    /// @dev Converts the OZ support value to a vote type, reverting on out-of-range values.
    function _toVoteType(uint8 support) private pure returns (IGovernanceVoting.VoteType) {
        require(support <= uint8(IGovernanceVoting.VoteType.Abstain), GovInvalidSupport(support));
        return IGovernanceVoting.VoteType(support);
    }

    function _castVoteBySig(
        uint256 proposalId,
        IGovernanceVoting.VoteType voteType,
        string memory reason,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal returns (uint256 weight) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(_name().value)),
                keccak256(bytes(VERSION)),
                block.chainid,
                address(this)
            )
        );
        bytes32 structHash = keccak256(abi.encode(VOTE_TYPEHASH, proposalId, uint8(voteType)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (address signatory, ECDSA.RecoverError recoverError) = ECDSA.tryRecover(digest, v, r, s);
        require(recoverError == ECDSA.RecoverError.NoError, GovInvalidSignature());
        weight = _castVote(signatory, proposalId, voteType, reason);
    }

    /// @inheritdoc IGovernanceVoting
    function execute(uint256 proposalId) external payable override {
        _executeProposal(proposalId);
    }

    /// @inheritdoc IOZGovernor
    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public payable override returns (uint256 proposalId) {
        bytes32 proposalHash = bytes32(hashProposal(targets, values, calldatas, descriptionHash));
        proposalId = _ozProposalIds().idByHash[proposalHash];
        require(proposalId != 0, GovProposalIdUnknown(proposalHash));
        _executeProposal(proposalId);
    }

    function _executeProposal(uint256 proposalId) internal {
        require(
            _getProposalState(proposalId) == IGovernanceState.ProposalStatus.Succeeded,
            GovVotingClosed(proposalId, _getProposalState(proposalId))
        );

        IGovernanceState.Proposal storage proposal = _proposal().proposalById[proposalId];
        proposal.executed = true;

        uint256 length = proposal.actionsLength;
        address strategy = _governanceParameters().strategy;

        // First pass: let the strategy prepare each action and compute the exact native amount required.
        IGovernanceVoting.ProposedAction[] memory preparedActions = new IGovernanceVoting.ProposedAction[](length);
        uint256 requiredValue;
        for (uint256 i = 0; i < length; i++) {
            IGovernanceVoting.ProposedAction memory action = _proposedAction().proposedActionbyIndex[proposalId][i];
            preparedActions[i] = IGovernanceStrategy(strategy).beforeExecute(action);
            requiredValue += preparedActions[i].value;
        }

        // Revert early if the caller did not attach enough native tokens.
        require(msg.value >= requiredValue, GovExecutionValueMismatch(requiredValue, msg.value));

        // Second pass: execute the prepared actions atomically.
        for (uint256 i = 0; i < length; i++) {
            GovernanceActionLib.execute(preparedActions[i]);
        }

        emit ProposalExecuted(proposalId);
    }

    /// @inheritdoc IGovernanceVoting
    function cancel(uint256 proposalId) external override {
        IGovernanceState.ProposalStatus state = _getProposalState(proposalId);
        require(state == IGovernanceState.ProposalStatus.Pending, GovVotingClosed(proposalId, state));

        ProposalMeta storage meta = _proposalMeta().proposalMetaById[proposalId];
        require(meta.proposer == msg.sender, GovUnableToCancel(proposalId, msg.sender));
        meta.canceled = true;

        emit ProposalCanceled(proposalId);
    }

    /// @notice Casts a vote for the given proposal.
    /// @dev Only callable during the voting period for that proposal.
    function _castVote(
        address voter,
        uint256 proposalId,
        IGovernanceVoting.VoteType voteType,
        string memory reason
    ) private returns (uint256 votingPower) {
        IGovernanceState.ProposalStatus state = _getProposalState(proposalId);
        require(state == IGovernanceState.ProposalStatus.Active, GovVotingClosed(proposalId, state));
        IGovernanceState.Receipt memory receipt = _receipt().userReceiptByProposal[proposalId][voter];
        require(!receipt.hasVoted, GovAlreadyVoted(proposalId, voter));
        votingPower = _getVotingPower(voter);
        require(votingPower > 0, GovNoVotes(voter));
        IGovernanceState.Proposal storage proposal = _proposal().proposalById[proposalId];

        if (voteType == IGovernanceVoting.VoteType.For) {
            proposal.votesFor += votingPower;
        } else if (voteType == IGovernanceVoting.VoteType.Against) {
            proposal.votesAgainst += votingPower;
        } else {
            proposal.votesAbstain += votingPower;
        }

        _receipt().userReceiptByProposal[proposalId][voter] = IGovernanceState.Receipt({
            hasVoted: true,
            votes: uint96(votingPower),
            voteType: voteType
        });

        // if vote reaches qualified majority we prepare execution at next block
        if (_getProposalState(proposalId) == IGovernanceState.ProposalStatus.Qualified) {
            proposal.endBlockOrTime = _paramsWrapper().governanceParameters.timeType == TimeType.Timestamp
                ? block.timestamp
                : block.number;
        }

        emit VoteCast(voter, proposalId, voteType, votingPower);

        // OZ-format event for Tally indexing, fired alongside the native one
        emit IOZGovernor.VoteCast(voter, proposalId, uint8(voteType), votingPower, reason);
    }
}
