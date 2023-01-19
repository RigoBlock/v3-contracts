// SPDX-License-Identifier: Apache-2.0
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

pragma solidity 0.8.17;

import "../utils/storageSlot/StorageSlot.sol";
import "../staking/interfaces/IStaking.sol";
import "../staking/interfaces/IStakingProxy.sol";
import "../staking/interfaces/IStorage.sol";
import "./IRigoblockGovernance.sol";

contract RigoblockGovernance is IRigoblockGovernance {
    /// Contract name
    string private constant CONTRACT_NAME = "Rigoblock Governance";

    /// Contract version
    string private constant CONTRACT_VERSION = "1.0.0";

    /// The EIP-712 typehash for the contract's domain
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// The EIP-712 typehash for the vote struct
    bytes32 private constant VOTE_TYPEHASH =
        keccak256("VoteEmitted(uint256 proposalId,bool support)");
    
    address private immutable _implementation;

    // Storage
    address public override stakingProxy;
    uint256 public override votingPeriod;
    bytes32 private domainSeparator;

    uint256 public override proposalThreshold;
    uint256 public override quorumThreshold;

    uint256 private _proposalsCount;
    mapping(uint256 => Proposal) private _proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    // locks direct calls to this contract
    modifier onlyDelegatecall() {
        assert(_implementation != address(this));
        _;
    }

    /// @notice Constructor has no inputs to guarantee same deterministic address.
    /// @dev Different parameters on each would result in different implementation address.
    /// @dev Setting staking proxy effectively locks direct calls to this contract.
    constructor() {
        _implementation = address(this);
        proposalThreshold = type(uint256).max; // more than will ever be GRG total supply
        stakingProxy = address(0);
    }

    /// @inheritdoc IRigoblockGovernance
    function initializeGovernance(
        address stakingProxy_,
        TreasuryParameters memory params
    )
        external
        onlyDelegatecall
        override
    {
        // assert uninitialized
        require(stakingProxy == address(0), "GOV_ALREADY_INIT_ERROR");
        require(params.votingPeriod < IStorage(stakingProxy_).epochDurationInSeconds(), "VOTING_PERIOD_TOO_LONG");
        stakingProxy = stakingProxy_;
        votingPeriod = params.votingPeriod;
        proposalThreshold = params.proposalThreshold;
        quorumThreshold = params.quorumThreshold;
        domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(CONTRACT_NAME)),
                block.chainid,
                keccak256(bytes(CONTRACT_VERSION)),
                address(this)
            )
        );
    }

    /// @notice Allows this contract to receive ether.
    receive() external payable onlyDelegatecall {}

    /// @inheritdoc IRigoblockGovernance
    function updateThresholds(uint256 newProposalThreshold, uint256 newQuorumThreshold)
        external
        onlyDelegatecall
        override
    {
        require(msg.sender == address(this), "GOV_UPGRADE_ONLY_SELF_ERROR");
        proposalThreshold = newProposalThreshold;
        quorumThreshold = newQuorumThreshold;
    }

    /// @inheritdoc IRigoblockGovernance
    function propose(
        ProposedAction[] memory actions,
        uint256 executionEpoch,
        string memory description
    ) external override returns (uint256 proposalId) {
        require(getVotingPower(msg.sender) >= proposalThreshold, "GOV_LOW_VOTING_POWER");
        require(actions.length > 0, "GOV_NO_ACTIONS_ERROR");
        uint256 currentEpoch = IStorage(stakingProxy).currentEpoch();
        require(executionEpoch >= currentEpoch + 2, "GOV_INVALID_EXECUTION_EPOCH");

        // TODO: fix style
        proposalId = proposalCount();
        _proposals[_proposalsCount] = Proposal({
            actionsHash: keccak256(abi.encode(actions)),
            executionEpoch: executionEpoch,
            voteEpoch: currentEpoch + 2,
            votesFor: 0,
            votesAgainst: 0,
            votesAbstain: 0,
            executed: false
        });
        ++_proposalsCount;

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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signatory = ecrecover(digest, v, r, s);

        return _castVote(signatory, proposalId, voteType);
    }

    /// @inheritdoc IRigoblockGovernance
    function execute(uint256 proposalId, ProposedAction[] memory actions) external payable override {
        if (proposalId >= proposalCount()) {
            revert("execute/INVALID_PROPOSAL_ID");
        }
        Proposal memory proposal = _proposals[proposalId];
        _assertProposalExecutable(proposal, actions);

        _proposals[proposalId].executed = true;

        for (uint256 i = 0; i != actions.length; i++) {
            ProposedAction memory action = actions[i];
            (bool didSucceed, ) = action.target.call{value: action.value}(action.data);
            require(didSucceed, "execute/ACTION_EXECUTION_FAILED");
        }

        emit ProposalExecuted(proposalId);
    }

    /// @inheritdoc IRigoblockGovernance
    function upgradeImplementation(address newImplementation) external onlyDelegatecall override {
        // upgrade must go through voting
        require(msg.sender == address(this), "GOV_UPGRADE_APPROVAL_ERROR");

        // we define the storage area where we will write new implementation as the eip1967 implementation slot
        bytes32 implementationSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assert(implementationSlot == bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1));

        // we read the current implementation address from the pool proxy storage
        address currentImplementation = StorageSlot.getAddressSlot(implementationSlot).value;

        // transaction reverted if implementation is same as current
        require(newImplementation != currentImplementation, "UPGRADE_SAME_AS_CURRENT_ERROR");

        // we write new address to storage at implementation slot location and emit eip1967 log
        StorageSlot.getAddressSlot(implementationSlot).value = newImplementation;
        emit Upgraded(newImplementation);
    }

    /// @inheritdoc IRigoblockGovernance
    function proposalCount() public view override returns (uint256 count) {
        return _proposalsCount;
    }

    /// @inheritdoc IRigoblockGovernance
    function getVotingPower(address account)
        public
        view
        override
        returns (uint256)
    {
        return IStaking(stakingProxy)
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
            IStorage(stakingProxy).currentEpoch() == proposal.executionEpoch,
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
        if (proposal.votesFor < quorumThreshold) {
            return false;
        }
        return true;
    }

    /// @notice Checks whether a vote starting at the given epoch has ended or not.
    /// @param voteEpoch The epoch at which the vote started.
    /// @return Boolean the vote has ended.
    function _hasVoteEnded(uint256 voteEpoch) private view returns (bool) {
        uint256 currentEpoch = IStorage(stakingProxy).currentEpoch();
        if (currentEpoch < voteEpoch) {
            return false;
        }
        if (currentEpoch > voteEpoch) {
            return true;
        }
        // voteEpoch == currentEpoch
        // Vote ends at currentEpochStartTime + votingPeriod
        uint256 voteEndTime = IStorage(stakingProxy).currentEpochStartTimeInSeconds() + votingPeriod;
        return block.timestamp > voteEndTime;
    }

    /// @notice Casts a vote for the given proposal.
    /// @dev Only callable during the voting period for that proposa.
    function _castVote(address voter, uint256 proposalId, VoteType voteType) private {
        if (proposalId >= proposalCount()) {
            revert("_castVote/INVALID_PROPOSAL_ID");
        }
        if (hasVoted[proposalId][voter]) {
            revert("_castVote/ALREADY_VOTED");
        }

        Proposal memory proposal = _proposals[proposalId];
        if (proposal.voteEpoch != IStorage(stakingProxy).currentEpoch() || _hasVoteEnded(proposal.voteEpoch)) {
            revert("_castVote/VOTING_IS_CLOSED");
        }

        uint256 votingPower = getVotingPower(voter);
        if (votingPower == 0) {
            revert("_castVote/NO_VOTING_POWER");
        }

        if (voteType == VoteType.FOR) {
            _proposals[proposalId].votesFor += votingPower;
        } else if (voteType == VoteType.AGAINST) {
            _proposals[proposalId].votesAgainst += votingPower;
        } else if (voteType == VoteType.ABSTAIN) {
            _proposals[proposalId].votesAbstain += votingPower;
        } else { revert("UNKNOWN_SUPPORT_TYPE_ERROR"); }

        hasVoted[proposalId][voter] = true;

        emit VoteCast(voter, proposalId, voteType, votingPower);
    }
}
