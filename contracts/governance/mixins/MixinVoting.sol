// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {ProposalStatus} from "../types/GovernanceTypes.sol";
import {IGovernanceState} from "../interfaces/governance/IGovernanceState.sol";
import {IGovernanceVoting} from "../interfaces/governance/IGovernanceVoting.sol";
import {IGovernanceStrategy} from "../interfaces/IGovernanceStrategy.sol";
import {IGovernor as IOZGovernor} from "@openzeppelin-gov/governance/IGovernor.sol";
import {EIP712} from "@openzeppelin-gov/utils/cryptography/EIP712.sol";
import {Nonces} from "@openzeppelin-gov/utils/Nonces.sol";
import {SignatureChecker} from "@openzeppelin-gov/utils/cryptography/SignatureChecker.sol";
import {TimeType} from "../types/TimeType.sol";
import {MixinAbstract} from "./MixinAbstract.sol";
import {MixinStorage} from "./MixinStorage.sol";
import {GovernanceActionLib} from "../libraries/GovernanceActionLib.sol";

abstract contract MixinVoting is Nonces, EIP712, MixinStorage, MixinAbstract {
    /// @notice OpenZeppelin Governor ballot typehash, including the voter and its nonce.
    bytes32 internal constant BALLOT_TYPEHASH =
        keccak256("Ballot(uint256 proposalId,uint8 support,address voter,uint256 nonce)");

    /// @notice OpenZeppelin Governor extended ballot typehash, including reason and params.
    bytes32 internal constant EXTENDED_BALLOT_TYPEHASH =
        keccak256(
            "ExtendedBallot(uint256 proposalId,uint8 support,address voter,uint256 nonce,string reason,bytes params)"
        );

    constructor() EIP712(_EIP712_NAME, VERSION) {}
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
    error GovVotingClosed(uint256 proposalId, ProposalStatus state);

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

    /// @notice Thrown when a vote signature is not valid for the claimed voter.
    /// @param voter The address whose signature failed validation.
    error GovInvalidSignature(address voter);

    /// @notice Thrown when queue is called: Rigoblock governance has no timelock.
    /// @param proposalId The id of the proposal that would have been queued.
    error GovQueueNotImplemented(uint256 proposalId);

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
            bytes32(_hashProposal(targets, values, calldatas, keccak256(bytes(description))))
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
        address voter,
        bytes memory signature
    ) public override returns (uint256 weight) {
        if (!_validateVoteSig(proposalId, support, voter, signature)) {
            revert GovInvalidSignature(voter);
        }
        weight = _castVote(voter, proposalId, _toVoteType(support), "");
    }

    /// @inheritdoc IOZGovernor
    function castVoteWithReasonAndParamsBySig(
        uint256 proposalId,
        uint8 support,
        address voter,
        string calldata reason,
        bytes memory params,
        bytes memory signature
    ) public override returns (uint256 weight) {
        if (!_validateExtendedVoteSig(proposalId, support, voter, reason, params, signature)) {
            revert GovInvalidSignature(voter);
        }
        weight = _castVote(voter, proposalId, _toVoteType(support), reason);
        if (params.length != 0) {
            uint256 votingPower = weight;
            emit IOZGovernor.VoteCastWithParams(voter, proposalId, support, votingPower, reason, params);
        }
    }

    /// @dev Validates the signature used in {castVoteBySig}, following the OpenZeppelin Governor.
    function _validateVoteSig(
        uint256 proposalId,
        uint8 support,
        address voter,
        bytes memory signature
    ) internal returns (bool) {
        return
            SignatureChecker.isValidSignatureNow(
                voter,
                _hashTypedDataV4(keccak256(abi.encode(BALLOT_TYPEHASH, proposalId, support, voter, _useNonce(voter)))),
                signature
            );
    }

    /// @dev Validates the signature used in {castVoteWithReasonAndParamsBySig}.
    function _validateExtendedVoteSig(
        uint256 proposalId,
        uint8 support,
        address voter,
        string calldata reason,
        bytes memory params,
        bytes memory signature
    ) internal returns (bool) {
        return
            SignatureChecker.isValidSignatureNow(
                voter,
                _hashTypedDataV4(
                    keccak256(
                        abi.encode(
                            EXTENDED_BALLOT_TYPEHASH,
                            proposalId,
                            support,
                            voter,
                            _useNonce(voter),
                            keccak256(bytes(reason)),
                            keccak256(params)
                        )
                    )
                ),
                signature
            );
    }

    /// @dev Converts the OZ support value to a vote type, reverting on out-of-range values.
    function _toVoteType(uint8 support) private pure returns (IGovernanceVoting.VoteType) {
        require(support <= uint8(IGovernanceVoting.VoteType.Abstain), GovInvalidSupport(support));
        return IGovernanceVoting.VoteType(support);
    }

    /// @inheritdoc IOZGovernor
    function queue(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) external override returns (uint256 proposalId) {
        // Rigoblock governance has no timelock: resolve the proposal for the revert reason.
        proposalId = _ozProposalIds().idByHash[bytes32(_hashProposal(targets, values, calldatas, descriptionHash))];
        revert GovQueueNotImplemented(proposalId);
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
        bytes32 proposalHash = bytes32(_hashProposal(targets, values, calldatas, descriptionHash));
        proposalId = _ozProposalIds().idByHash[proposalHash];
        require(proposalId != 0, GovProposalIdUnknown(proposalHash));
        _executeProposal(proposalId);
    }

    function _executeProposal(uint256 proposalId) internal {
        require(
            _getProposalState(proposalId) == ProposalStatus.Succeeded,
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
        _cancel(proposalId);
    }

    /// @inheritdoc IOZGovernor
    function cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) external override returns (uint256 proposalId) {
        bytes32 proposalHash = bytes32(_hashProposal(targets, values, calldatas, descriptionHash));
        proposalId = _ozProposalIds().idByHash[proposalHash];
        require(proposalId != 0, GovProposalIdUnknown(proposalHash));
        _cancel(proposalId);
    }

    function _cancel(uint256 proposalId) internal {
        ProposalStatus state = _getProposalState(proposalId);
        require(state == ProposalStatus.Pending, GovVotingClosed(proposalId, state));

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
        ProposalStatus state = _getProposalState(proposalId);
        require(state == ProposalStatus.Active, GovVotingClosed(proposalId, state));
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
        if (_getProposalState(proposalId) == ProposalStatus.Qualified) {
            proposal.endBlockOrTime = _paramsWrapper().governanceParameters.timeType == TimeType.Timestamp
                ? block.timestamp
                : block.number;
        }

        emit VoteCast(voter, proposalId, voteType, votingPower);

        // OZ-format event for Tally indexing, fired alongside the native one
        emit IOZGovernor.VoteCast(voter, proposalId, uint8(voteType), votingPower, reason);
    }
}
