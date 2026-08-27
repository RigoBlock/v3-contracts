// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {IGovernanceState} from "../interfaces/governance/IGovernanceState.sol";
import {IGovernanceVoting} from "../interfaces/governance/IGovernanceVoting.sol";
import {IGovernanceStrategy} from "../interfaces/IGovernanceStrategy.sol";
import {MixinAbstract} from "./MixinAbstract.sol";
import {MixinStorage} from "./MixinStorage.sol";

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
    error GovVotingClosed(uint256 proposalId, IGovernanceState.ProposalState state);

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

    /// @notice Thrown when refunding excess native tokens to the caller fails.
    error GovRefundFailed();

    /// @inheritdoc IGovernanceVoting
    function propose(
        IGovernanceVoting.ProposedAction[] memory actions,
        string memory description
    ) external override returns (uint256 proposalId) {
        uint256 length = actions.length;
        uint256 proposalThreshold = _governanceParameters().proposalThreshold;
        require(
            _getVotingPower(msg.sender) >= proposalThreshold,
            GovLowVotingPower(_getVotingPower(msg.sender), proposalThreshold)
        );
        require(length > 0, GovNoActions());
        require(length <= PROPOSAL_MAX_OPERATIONS, GovTooManyActions(length, PROPOSAL_MAX_OPERATIONS));

        address strategy = _governanceParameters().strategy;
        (uint256 startBlockOrTime, uint256 endBlockOrTime) = IGovernanceStrategy(strategy).votingTimestamps();

        // proposals start from id = 1
        _proposalCount().value++;
        proposalId = _getProposalCount();
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
    }

    /// @inheritdoc IGovernanceVoting
    function castVote(uint256 proposalId, IGovernanceVoting.VoteType voteType) external override {
        _castVote(msg.sender, proposalId, voteType);
    }

    /// @inheritdoc IGovernanceVoting
    function castVoteBySignature(
        uint256 proposalId,
        IGovernanceVoting.VoteType voteType,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(_name().value)),
                keccak256(bytes(VERSION)),
                block.chainid,
                address(this)
            )
        );
        bytes32 structHash = keccak256(abi.encode(VOTE_TYPEHASH, proposalId, voteType));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signatory = ecrecover(digest, v, r, s);
        // following assertion is always bypassed by producing a valid EIP712 signature on diff. domain, therefore we do not return an error
        assert(
            signatory != address(0) && uint256(s) <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0
        );
        _castVote(signatory, proposalId, voteType);
    }

    /// @inheritdoc IGovernanceVoting
    function execute(uint256 proposalId) external payable override {
        require(
            _getProposalState(proposalId) == IGovernanceState.ProposalState.Succeeded,
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
            IGovernanceVoting.ProposedAction memory action = preparedActions[i];
            address target = action.target;
            uint256 value = action.value;
            bytes memory data = action.data;

            // we revert with error returned from the target
            // solhint-disable-next-line no-inline-assembly
            assembly {
                let didSucceed := call(gas(), target, value, add(data, 0x20), mload(data), 0, 0)
                returndatacopy(0, 0, returndatasize())
                if eq(didSucceed, 0) {
                    revert(0, returndatasize())
                }
            }
        }

        emit ProposalExecuted(proposalId);
    }

    /// @notice Casts a vote for the given proposal.
    /// @dev Only callable during the voting period for that proposal.
    function _castVote(address voter, uint256 proposalId, IGovernanceVoting.VoteType voteType) private {
        IGovernanceState.ProposalState state = _getProposalState(proposalId);
        require(state == IGovernanceState.ProposalState.Active, GovVotingClosed(proposalId, state));
        IGovernanceState.Receipt memory receipt = _receipt().userReceiptByProposal[proposalId][voter];
        require(!receipt.hasVoted, GovAlreadyVoted(proposalId, voter));
        uint256 votingPower = _getVotingPower(voter);
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
        if (_getProposalState(proposalId) == IGovernanceState.ProposalState.Qualified) {
            proposal.endBlockOrTime = _paramsWrapper().governanceParameters.timeType == IGovernanceState.TimeType.Timestamp
                ? block.timestamp
                : block.number;
        }

        emit VoteCast(voter, proposalId, voteType, votingPower);
    }
}
