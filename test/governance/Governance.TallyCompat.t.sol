// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {ProposalStatus} from "../../contracts/governance/types/GovernanceTypes.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MixinCrosschain} from "../../contracts/governance/mixins/MixinCrosschain.sol";
import {MixinAbstract} from "../../contracts/governance/mixins/MixinAbstract.sol";
import {MixinStorage} from "../../contracts/governance/mixins/MixinStorage.sol";
import {MixinState} from "../../contracts/governance/mixins/MixinState.sol";
import {MixinVoting} from "../../contracts/governance/mixins/MixinVoting.sol";
import {MixinInitializer} from "../../contracts/governance/mixins/MixinInitializer.sol";
import {MixinUpgrade} from "../../contracts/governance/mixins/MixinUpgrade.sol";
import {IGovernanceState} from "../../contracts/governance/interfaces/governance/IGovernanceState.sol";
import {IGovernanceEvents} from "../../contracts/governance/interfaces/governance/IGovernanceEvents.sol";
import {IGovernanceVoting} from "../../contracts/governance/interfaces/governance/IGovernanceVoting.sol";
import {IGovernanceUpgrade} from "../../contracts/governance/interfaces/governance/IGovernanceUpgrade.sol";
import {IRigoblockGovernance} from "../../contracts/governance/IRigoblockGovernance.sol";
import {IGovernanceStrategy} from "../../contracts/governance/interfaces/IGovernanceStrategy.sol";
import {IRigoblockGovernanceFactory} from "../../contracts/governance/interfaces/IRigoblockGovernanceFactory.sol";
import {IGovernor as OZGovernor} from "@openzeppelin-gov/governance/IGovernor.sol";
import {IERC165} from "@openzeppelin-gov/utils/introspection/IERC165.sol";
import {IERC6372} from "@openzeppelin-gov/interfaces/IERC6372.sol";
import {IERC5267} from "@openzeppelin-gov/interfaces/IERC5267.sol";
import {TimeType} from "../../contracts/governance/types/TimeType.sol";

/// @dev Emits OZ-format events so tests can compare topics against the ones the mixins emit.
///     Event identity is the topic hash, so no inheritance from the OZ interface is needed.
contract OZEventEmitter {
    event VoteCast(address indexed voter, uint256 proposalId, uint8 support, uint256 weight, string reason);

    event ProposalCreated(
        uint256 proposalId,
        address proposer,
        address[] targets,
        uint256[] values,
        string[] signatures,
        bytes[] calldatas,
        uint256 startBlock,
        uint256 endBlock,
        string description
    );

    event VoteCastWithParams(
        address indexed voter,
        uint256 proposalId,
        uint8 support,
        uint256 weight,
        string reason,
        bytes params
    );

    function emitVoteCastWithParams(
        address voter,
        uint256 proposalId,
        uint8 support,
        uint256 weight,
        string calldata reason,
        bytes calldata params
    ) external {
        emit VoteCastWithParams(voter, proposalId, support, weight, reason, params);
    }

    function emitVoteCast(
        address voter,
        uint256 proposalId,
        uint8 support,
        uint256 weight,
        string calldata reason
    ) external {
        emit VoteCast(voter, proposalId, support, weight, reason);
    }

    function emitProposalCreated(
        uint256 proposalId,
        address proposer,
        address[] memory targets,
        uint256[] memory values,
        string[] memory signatures,
        bytes[] memory calldatas,
        uint256 startBlock,
        uint256 endBlock,
        string memory description
    ) external {
        emit ProposalCreated(
            proposalId,
            proposer,
            targets,
            values,
            signatures,
            calldatas,
            startBlock,
            endBlock,
            description
        );
    }
}

/// @dev Minimal strategy sufficient for the compat tests: fixed voting power and a
///     timestamp-based voting window ending within reasonable test warps.
contract MockCompatStrategy is IGovernanceStrategy {
    uint256 public immutable votingPower;
    uint256 public immutable proposalThreshold;
    uint256 public immutable quorumThreshold;

    constructor(uint256 votingPower_, uint256 proposalThreshold_, uint256 quorumThreshold_) {
        votingPower = votingPower_;
        proposalThreshold = proposalThreshold_;
        quorumThreshold = quorumThreshold_;
    }

    function assertValidInitParams(IRigoblockGovernanceFactory.Parameters calldata) external pure {}

    function assertValidProposalThreshold(uint256) external pure {}

    function assertValidQuorumThreshold(uint256) external pure {}

    function requestRecover() external pure override {
        revert();
    }

    function rejectRecover() external pure override {
        revert();
    }

    function getProposalState(
        IRigoblockGovernance.Proposal memory proposal,
        uint256 minimumQuorum,
        TimeType timeType
    ) external view returns (ProposalStatus) {
        assert(timeType == TimeType.Timestamp);
        if (block.timestamp <= proposal.startBlockOrTime) {
            return ProposalStatus.Pending;
        } else if (block.timestamp <= proposal.endBlockOrTime && _qualified(proposal, minimumQuorum)) {
            return ProposalStatus.Qualified;
        } else if (block.timestamp <= proposal.endBlockOrTime) {
            return ProposalStatus.Active;
        } else if (proposal.votesFor <= 2 * proposal.votesAgainst || proposal.votesFor < minimumQuorum) {
            return ProposalStatus.Defeated;
        } else if (proposal.executed) {
            return ProposalStatus.Executed;
        } else {
            return ProposalStatus.Succeeded;
        }
    }

    function _qualified(
        IRigoblockGovernance.Proposal memory proposal,
        uint256 minimumQuorum
    ) private pure returns (bool) {
        return proposal.votesFor > 2 * proposal.votesAgainst && proposal.votesFor >= minimumQuorum;
    }

    function votingPeriod() external pure returns (uint256) {
        return 7 days;
    }

    function votingTimestamps(
        TimeType timeType
    ) external view returns (uint256 startBlockOrTime, uint256 endBlockOrTime) {
        assert(timeType == TimeType.Timestamp);
        startBlockOrTime = block.timestamp + 1;
        endBlockOrTime = startBlockOrTime + 7 days;
    }

    function getVotingPower(address) external view returns (uint256) {
        return votingPower;
    }

    function beforePropose(
        IRigoblockGovernance.ProposedAction calldata action
    ) external pure returns (IRigoblockGovernance.ProposedAction memory) {
        return action;
    }

    function beforeExecute(
        IRigoblockGovernance.ProposedAction calldata action
    ) external pure returns (IRigoblockGovernance.ProposedAction memory) {
        return action;
    }

    function wormhole() external pure returns (address) {
        return address(0);
    }

    function wormholeChainId() external pure returns (uint16) {
        return 0;
    }
}

/// @dev Harness using the real mixins, same pattern as the migration tests.
contract CompatHarness is MixinStorage, MixinInitializer, MixinVoting, MixinUpgrade, MixinCrosschain {
    constructor() MixinStorage() {}

    function setStrategy(address strategy_) external {
        _paramsWrapper().governanceParameters.strategy = strategy_;
    }

    function setParams(uint256 proposalThreshold_, uint256 quorumThreshold_) external {
        _paramsWrapper().governanceParameters.proposalThreshold = proposalThreshold_;
        _paramsWrapper().governanceParameters.quorumThreshold = quorumThreshold_;
    }

    function setTimeType(TimeType timeType_) external {
        _paramsWrapper().governanceParameters.timeType = timeType_;
    }

    function quorumReached(uint256 proposalId) external view returns (bool) {
        return _quorumReached(proposalId);
    }

    function voteSucceeded(uint256 proposalId) external view returns (bool) {
        return _voteSucceeded(proposalId);
    }
}

contract MockCompatTarget {
    uint256 public calls;

    fallback() external payable {
        calls++;
    }
}

/// @title GovernanceTallyCompatTest
/// @notice Verifies the OpenZeppelin Governor / Tally compatibility surface, which the
///     governance now exposes by directly inheriting OZ's IGovernor and IERC6372:
///     clock, OZ state numbering, OZ propose/execute flows, dual ProposalCreated / VoteCast
///     events, support values (0 = Against, 1 = For, 2 = Abstain) and the view shims.
///     Specification: docs/governance/TALLY_COMPAT.md.
contract GovernanceTallyCompatTest is Test {
    CompatHarness internal harness;
    MockCompatStrategy internal strategy;
    MockCompatTarget internal compatTarget;

    address internal whale = makeAddr("whale");
    address internal voter2 = makeAddr("voter2");

    uint256 internal constant VOTING_POWER = 2_000_000e18;
    uint256 internal constant PROPOSAL_THRESHOLD = 100_000e18;
    uint256 internal constant QUORUM = 1_000_000e18;

    function setUp() public {
        harness = new CompatHarness();
        strategy = new MockCompatStrategy(VOTING_POWER, PROPOSAL_THRESHOLD, QUORUM);
        compatTarget = new MockCompatTarget();
        harness.setStrategy(address(strategy));
        harness.setParams(PROPOSAL_THRESHOLD, QUORUM);
        harness.setTimeType(TimeType.Timestamp);
    }

    /// @notice IERC6372: clock is the current timestamp, mode is timestamp-based.
    function test_Clock_ReturnsTimestamp() public {
        assertEq(harness.clock(), uint48(block.timestamp));
        assertEq(harness.CLOCK_MODE(), "mode=timestamp");
        vm.warp(block.timestamp + 1234);
        assertEq(harness.clock(), uint48(block.timestamp));
    }

    /// @notice ERC-165: the governance declares the OZ Governor, ERC-6372 and ERC-5267 interfaces.
    function test_SupportsInterface_DeclaresOZCompatibility() public {
        assertTrue(harness.supportsInterface(type(IERC165).interfaceId));
        assertTrue(harness.supportsInterface(type(OZGovernor).interfaceId));
        assertTrue(harness.supportsInterface(type(IERC6372).interfaceId));
        assertTrue(harness.supportsInterface(type(IERC5267).interfaceId));
        assertFalse(harness.supportsInterface(bytes4(0xdeadbeef)));
    }

    /// @notice COUNTING_MODE describes bravo support values and For-only quorum counting.
    function test_CountingMode_DescribesSupportAndQuorum() public {
        assertEq(harness.COUNTING_MODE(), "support=bravo&quorum=bravo");
    }

    /// @notice `state()` translates the native enum into the OZ Governor numbering without
    ///     touching the native enum: values up to Canceled are identical, Qualified maps to
    ///     OZ Succeeded, and higher native values shift down one position. The native
    ///     `getProposalState` keeps its historical numbering.
    function test_StateNumbering_MatchesOpenZeppelin() public {
        // native numbering is untouched
        assertEq(uint8(ProposalStatus.Pending), 0);
        assertEq(uint8(ProposalStatus.Active), 1);
        assertEq(uint8(ProposalStatus.Canceled), 2);
        assertEq(uint8(ProposalStatus.Qualified), 3);
        assertEq(uint8(ProposalStatus.Defeated), 4);
        assertEq(uint8(ProposalStatus.Succeeded), 5);
        assertEq(uint8(ProposalStatus.Executed), 8);

        uint256 proposalId = _proposeDefault();
        assertEq(uint8(harness.getProposalState(proposalId)), uint8(ProposalStatus.Pending));
        assertEq(uint8(harness.state(proposalId)), uint8(OZGovernor.ProposalState.Pending));
    }

    /// @notice End-to-end translation: native states driven through the real state machine
    ///     map to the expected OZ values.
    function test_StateMapping_EndToEnd() public {
        // Canceled is at index 2 in both numberings
        uint256 canceledId = _proposeDefault();
        vm.prank(whale);
        harness.cancel(canceledId);
        assertEq(uint8(harness.state(canceledId)), uint8(OZGovernor.ProposalState.Canceled));

        // Qualified has no OZ equivalent: it maps to OZ Succeeded (4)
        uint256 qualifiedId = _proposeDefault();
        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        harness.castVote(qualifiedId, uint8(IGovernanceVoting.VoteType.For)); // For, reaches qualified majority
        assertEq(uint8(harness.getProposalState(qualifiedId)), uint8(ProposalStatus.Qualified));
        assertEq(uint8(harness.state(qualifiedId)), uint8(OZGovernor.ProposalState.Succeeded));

        // native Defeated (4) shifts down to OZ Defeated (3)
        uint256 defeatedId = _proposeDefault();
        vm.warp(block.timestamp + 2);
        vm.prank(voter2);
        harness.castVote(defeatedId, uint8(IGovernanceVoting.VoteType.Against)); // Against
        IGovernanceState.ProposalWrapper memory wrapper = harness.getProposalById(defeatedId);
        vm.warp(wrapper.proposal.endBlockOrTime + 1);
        assertEq(uint8(harness.getProposalState(defeatedId)), uint8(ProposalStatus.Defeated));
        assertEq(uint8(harness.state(defeatedId)), uint8(OZGovernor.ProposalState.Defeated));

        // native Succeeded (5) shifts down to OZ Succeeded (4); Executed (8) to OZ Executed (7)
        uint256 succeededId = _proposeDefault();
        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        harness.castVote(succeededId, uint8(IGovernanceVoting.VoteType.For));
        wrapper = harness.getProposalById(succeededId);
        vm.warp(wrapper.proposal.endBlockOrTime + 1);
        assertEq(uint8(harness.getProposalState(succeededId)), uint8(ProposalStatus.Succeeded));
        assertEq(uint8(harness.state(succeededId)), uint8(OZGovernor.ProposalState.Succeeded));

        vm.prank(whale);
        harness.execute(succeededId);
        assertEq(uint8(harness.getProposalState(succeededId)), uint8(ProposalStatus.Executed));
        assertEq(uint8(harness.state(succeededId)), uint8(OZGovernor.ProposalState.Executed));
    }

    /// @notice The OZ hash-based `cancel` resolves the proposal from its content hash, enforces
    ///     proposer auth, and cancels it exactly like the id-based entry point.
    function test_Cancel_ByProposalHash_Succeeds() public {
        address[] memory targets = new address[](1);
        targets[0] = address(compatTarget);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        bytes32 descriptionHash = keccak256(bytes("proposal"));

        uint256 proposalId = _proposeDefault();
        assertEq(uint8(harness.state(proposalId)), uint8(OZGovernor.ProposalState.Pending));

        vm.expectEmit(true, false, false, true);
        emit OZGovernor.ProposalCanceled(proposalId);
        vm.prank(whale);
        uint256 canceledId = harness.cancel(targets, values, calldatas, descriptionHash);
        assertEq(canceledId, proposalId);
        assertEq(uint8(harness.state(proposalId)), uint8(OZGovernor.ProposalState.Canceled));

        // the same hash form enforces proposer auth on a still-pending proposal
        uint256 otherId = _proposeDefault();
        vm.prank(voter2);
        vm.expectRevert(abi.encodeWithSelector(MixinVoting.GovUnableToCancel.selector, otherId, voter2));
        harness.cancel(targets, values, calldatas, descriptionHash);
    }

    /// @notice castVoteWithReason records the vote and emits the OZ VoteCast event carrying
    ///     the reason string; the native event stays reason-free.
    function test_CastVoteWithReason_EmitsReasonInOZEvent() public {
        uint256 proposalId = _proposeDefault();
        vm.warp(block.timestamp + 2);

        vm.expectEmit(true, true, false, true);
        emit IGovernanceEvents.VoteCast(whale, proposalId, IGovernanceVoting.VoteType.For, VOTING_POWER);

        vm.expectEmit(true, true, false, true);
        emit OZEventEmitter.VoteCast(whale, proposalId, 1, VOTING_POWER, "looks good");

        vm.prank(whale);
        uint256 weight = harness.castVoteWithReason(proposalId, 1, "looks good");
        assertEq(weight, VOTING_POWER);
    }

    /// @notice hasVoted exposes vote receipts in OZ shape.
    function test_HasVoted() public {
        uint256 proposalId = _proposeDefault();
        assertFalse(harness.hasVoted(proposalId, whale));

        vm.warp(block.timestamp + 2);
        vm.prank(voter2);
        harness.castVote(proposalId, uint8(IGovernanceVoting.VoteType.Against)); // Against
        vm.prank(whale);
        harness.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For)); // For

        assertTrue(harness.hasVoted(proposalId, whale));
        assertFalse(harness.hasVoted(proposalId, makeAddr("nobody")));
    }

    /// @notice Selector identity with OpenZeppelin's interface is compile-enforced: the
    ///     mixins implement castVote/state/quorum/etc. as overrides of OZ's IGovernor, so
    ///     any OZ signature change breaks the build. The behavioral tests below exercise
    ///     each OZ entry point end-to-end against the real mixins.

    /// @notice The OZ VoteCast topic must match the one emitted by the OZ interface, and the
    ///     OZ ProposalCreated topic must be fired at propose time.
    function test_EventTopics_MatchOpenZeppelin() public {
        OZEventEmitter emitter = new OZEventEmitter();

        vm.recordLogs();
        emitter.emitVoteCast(whale, 1, 1, VOTING_POWER, "reason");
        Vm.Log[] memory ozLogs = vm.getRecordedLogs();
        assertEq(ozLogs.length, 1);

        uint256 proposalId = _proposeDefault();
        vm.warp(block.timestamp + 2);
        vm.recordLogs();
        vm.prank(whale);
        harness.castVoteWithReason(proposalId, 1, "reason");
        Vm.Log[] memory ourLogs = vm.getRecordedLogs();
        // native VoteCast + OZ VoteCast
        assertEq(ourLogs.length, 2);
        bytes32 ozVoteCastTopic = ozLogs[0].topics[0];
        bool found;
        for (uint256 i = 0; i < ourLogs.length; i++) {
            if (ourLogs[i].topics[0] == ozVoteCastTopic) {
                found = true;
                // topics: event sig, voter (indexed)
                assertEq(ourLogs[i].topics[1], bytes32(uint256(uint160(whale))));
            }
        }
        assertTrue(found);

        vm.recordLogs();
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        string[] memory signatures = new string[](1);
        emitter.emitProposalCreated(2, whale, targets, values, signatures, calldatas, 1, 2, "d");
        bytes32 ozProposalCreatedTopic = vm.getRecordedLogs()[0].topics[0];

        vm.recordLogs();
        _propose(_toActions(targets, values, calldatas), "d");
        Vm.Log[] memory proposeLogs = vm.getRecordedLogs();
        found = false;
        for (uint256 i = 0; i < proposeLogs.length; i++) {
            if (proposeLogs[i].topics[0] == ozProposalCreatedTopic) {
                found = true;
            }
        }
        assertTrue(found);
    }

    /// @notice version() reports the same contract version as governanceParameters().
    function test_Version_MatchesGovernanceParameters() public {
        assertEq(harness.version(), harness.governanceParameters().version);
    }

    /// @notice The OZ propose overload assembles the same actions as the native propose
    ///     and fires both the native and the OZ-format ProposalCreated events.
    function test_OZPropose_CreatesProposal_AndEmitsBothEvents() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(compatTarget);
        values[0] = 0;
        calldatas[0] = hex"";

        vm.expectEmit(true, true, false, true);
        emit IGovernanceEvents.ProposalCreated(
            whale,
            1,
            _toActions(targets, values, calldatas),
            block.timestamp + 1,
            block.timestamp + 1 + 7 days,
            "oz proposal"
        );

        vm.expectEmit(true, true, false, true);
        emit OZEventEmitter.ProposalCreated(
            1,
            whale,
            targets,
            values,
            new string[](1),
            calldatas,
            block.timestamp + 1,
            block.timestamp + 1 + 7 days,
            "oz proposal"
        );

        vm.prank(whale);
        uint256 proposalId = harness.propose(targets, values, calldatas, "oz proposal");
        assertEq(proposalId, 1);

        IGovernanceVoting.ProposedAction[] memory actions = harness.getActions(proposalId);
        assertEq(actions.length, 1);
        assertEq(actions[0].target, address(compatTarget));
        assertEq(actions[0].value, 0);
        assertEq(actions[0].data, hex"");
    }

    /// @notice OZ propose reverts on mismatched array lengths before any state is written.
    function test_OZPropose_LengthMismatch_Reverts() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](1);
        vm.prank(whale);
        vm.expectRevert(MixinVoting.GovActionsLengthMismatch.selector);
        harness.propose(targets, values, calldatas, "bad");
    }

    /// @notice Support mapping: 0 = Against, 1 = For, 2 = Abstain, matching OZ Governor.
    ///     Votes are counted against the proposal tallies and receipts store the
    ///     internal VoteType.
    function test_SupportMapping_CountsVotesCorrectly() public {
        uint256 proposalId = _proposeDefault();
        vm.warp(block.timestamp + 2);

        // Against first: it does not qualify the proposal, so voting remains open.
        vm.prank(voter2);
        harness.castVote(proposalId, uint8(IGovernanceVoting.VoteType.Against)); // Against

        vm.prank(whale);
        uint256 weight = harness.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For)); // For
        assertEq(weight, VOTING_POWER);

        IGovernanceState.ProposalWrapper memory wrapper = harness.getProposalById(proposalId);
        assertEq(wrapper.proposal.votesFor, VOTING_POWER);
        assertEq(wrapper.proposal.votesAgainst, VOTING_POWER);
        assertEq(wrapper.proposal.votesAbstain, 0);

        IGovernanceState.Receipt memory receipt = harness.getReceipt(proposalId, whale);
        assertTrue(receipt.hasVoted);
        assertEq(uint256(receipt.voteType), uint256(IGovernanceVoting.VoteType.For));

        // Abstain counts towards neither tally but records the vote.
        uint256 proposalId2 = _proposeDefault();
        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        harness.castVote(proposalId2, uint8(IGovernanceVoting.VoteType.Abstain)); // Abstain
        IGovernanceState.ProposalWrapper memory wrapper2 = harness.getProposalById(proposalId2);
        assertEq(wrapper2.proposal.votesFor, 0);
        assertEq(wrapper2.proposal.votesAgainst, 0);
        assertEq(wrapper2.proposal.votesAbstain, VOTING_POWER);
    }

    /// @notice Out-of-range support values revert instead of panicking.
    function test_CastVote_InvalidSupport_Reverts() public {
        uint256 proposalId = _proposeDefault();
        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        vm.expectRevert(abi.encodeWithSelector(MixinVoting.GovInvalidSupport.selector, uint8(3)));
        harness.castVote(proposalId, 3);
    }

    /// @notice castVote emits both the native and the OZ-format VoteCast events.
    function test_VoteCast_EmitsBothEvents() public {
        uint256 proposalId = _proposeDefault();
        vm.warp(block.timestamp + 2);

        vm.expectEmit(true, true, false, true);
        emit IGovernanceEvents.VoteCast(whale, proposalId, IGovernanceVoting.VoteType.For, VOTING_POWER);

        vm.expectEmit(true, true, false, true);
        emit OZEventEmitter.VoteCast(whale, proposalId, 1, VOTING_POWER, "");

        vm.prank(whale);
        harness.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
    }

    /// @notice castVoteWithReasonAndParams counts the vote and, with non-empty params,
    ///     additionally emits the OZ VoteCastWithParams event.
    function test_CastVoteWithReasonAndParams_EmitsParamsEvent() public {
        OZEventEmitter emitter = new OZEventEmitter();
        vm.recordLogs();
        emitter.emitVoteCastWithParams(whale, 1, 1, VOTING_POWER, "r", hex"01");
        bytes32 paramsTopic = vm.getRecordedLogs()[0].topics[0];

        uint256 proposalId = _proposeDefault();
        vm.warp(block.timestamp + 2);

        vm.expectEmit(true, true, false, true);
        emit IGovernanceEvents.VoteCast(whale, proposalId, IGovernanceVoting.VoteType.For, VOTING_POWER);

        vm.expectEmit(true, true, false, false);
        emit OZEventEmitter.VoteCastWithParams(whale, proposalId, 1, VOTING_POWER, "r", hex"01");

        vm.prank(whale);
        uint256 weight = harness.castVoteWithReasonAndParams(proposalId, 1, "r", hex"01");
        assertEq(weight, VOTING_POWER);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == paramsTopic) {
                found = true;
            }
        }
        assertTrue(found);
    }

    /// @notice castVoteBySig verifies the OZ Governor ballot signature: fixed domain name/version
    ///     (OZ EIP712 constructor immutables) and the OZ Ballot typehash with voter and nonce.
    function test_CastVoteBySig_VerifiesOZSignature() public {
        uint256 proposalId = _proposeDefault();
        vm.warp(block.timestamp + 2);

        uint256 privateKey = 0xA11CE;
        address signatory = vm.addr(privateKey);
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Rigoblock Governance")),
                keccak256(bytes("1.3.0")),
                block.chainid,
                address(harness)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Ballot(uint256 proposalId,uint8 support,address voter,uint256 nonce)"),
                proposalId,
                uint8(1),
                signatory,
                uint256(0)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 weight = harness.castVoteBySig(proposalId, 1, signatory, signature);
        assertEq(weight, VOTING_POWER);
        assertTrue(harness.hasVoted(proposalId, signatory));
        assertEq(harness.nonces(signatory), 1);
    }

    /// @notice The consumed voter nonce lands in the ERC-7201 namespaced slot, while the sequential
    ///     slots reserved by the OZ `Nonces`/`EIP712` base contracts stay untouched.
    function test_VoterNonces_StoredInNamespacedSlot() public {
        uint256 proposalId = _proposeDefault();
        vm.warp(block.timestamp + 2);

        uint256 privateKey = 0xB0B;
        address signatory = vm.addr(privateKey);
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Rigoblock Governance")),
                keccak256(bytes("1.3.0")),
                block.chainid,
                address(harness)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Ballot(uint256 proposalId,uint8 support,address voter,uint256 nonce)"),
                proposalId,
                uint8(1),
                signatory,
                uint256(0)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        harness.castVoteBySig(proposalId, 1, signatory, abi.encodePacked(r, s, v));

        bytes32 noncesSlot = bytes32(uint256(keccak256("governance.proxy.voter.nonces")) - 1);
        bytes32 voterNonceSlot = keccak256(abi.encode(signatory, noncesSlot));
        assertEq(vm.load(address(harness), voterNonceSlot), bytes32(uint256(1)));
        assertEq(vm.load(address(harness), bytes32(uint256(0))), 0);
        assertEq(vm.load(address(harness), bytes32(uint256(1))), 0);
        assertEq(vm.load(address(harness), bytes32(uint256(2))), 0);
    }

    /// @notice castVoteWithReasonAndParamsBySig verifies the OZ ExtendedBallot signature
    ///     (reason and params bound into the digest) and consumes the voter nonce.
    function test_CastVoteWithReasonAndParamsBySig_VerifiesOZSignature() public {
        uint256 proposalId = _proposeDefault();
        vm.warp(block.timestamp + 2);

        uint256 privateKey = 0xB0B;
        address signatory = vm.addr(privateKey);
        string memory reason = "r";
        bytes memory params = hex"01";
        bytes32 digest = _extendedBallotDigest(proposalId, 1, signatory, 0, reason, params);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        uint256 weight = harness.castVoteWithReasonAndParamsBySig(
            proposalId,
            1,
            signatory,
            reason,
            params,
            abi.encodePacked(r, s, v)
        );
        assertEq(weight, VOTING_POWER);
        assertTrue(harness.hasVoted(proposalId, signatory));
        assertEq(harness.nonces(signatory), 1);
    }

    /// @notice A signature bound to different params no longer validates (fresh nonce, same proposal).
    function test_CastVoteWithReasonAndParamsBySig_DifferentParamsReverts() public {
        uint256 proposalId = _proposeDefault();
        vm.warp(block.timestamp + 2);

        uint256 privateKey = 0xB0B;
        address signatory = vm.addr(privateKey);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            _extendedBallotDigest(proposalId, 1, signatory, 0, "r", hex"01")
        );

        vm.expectRevert(abi.encodeWithSelector(OZGovernor.GovernorInvalidSignature.selector, signatory));
        harness.castVoteWithReasonAndParamsBySig(proposalId, 1, signatory, "r", hex"02", abi.encodePacked(r, s, v));
    }

    function _extendedBallotDigest(
        uint256 proposalId,
        uint8 support,
        address signatory,
        uint256 nonce,
        string memory reason,
        bytes memory params
    ) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Rigoblock Governance")),
                keccak256(bytes("1.3.0")),
                block.chainid,
                address(harness)
            )
        );
        return
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    domainSeparator,
                    keccak256(
                        abi.encode(
                            keccak256(
                                "ExtendedBallot(uint256 proposalId,uint8 support,address voter,uint256 nonce,string reason,bytes params)"
                            ),
                            proposalId,
                            support,
                            signatory,
                            nonce,
                            keccak256(bytes(reason)),
                            keccak256(params)
                        )
                    )
                )
            );
    }

    /// @notice The OZ execute flow resolves the proposal through the stored OZ proposal hash
    ///     and executes the same actions as the native execute(proposalId).
    function test_OZExecute_ResolvesProposalByHash() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(compatTarget);
        calldatas[0] = hex"";

        uint256 proposalId = _propose(_toActions(targets, values, calldatas), "oz execute");
        _voteAndWarpPast(proposalId, uint8(IGovernanceVoting.VoteType.For));

        vm.expectEmit(true, true, false, true);
        emit OZGovernor.ProposalExecuted(proposalId);

        uint256 executedId = harness.execute(targets, values, calldatas, keccak256("oz execute"));
        assertEq(executedId, proposalId);
        assertEq(compatTarget.calls(), 1);

        // an unknown hash reverts
        vm.expectRevert(
            abi.encodeWithSelector(
                MixinVoting.GovProposalIdUnknown.selector,
                bytes32(harness.hashProposal(targets, values, calldatas, keccak256("unknown")))
            )
        );
        harness.execute(targets, values, calldatas, keccak256("unknown"));
    }

    /// @notice View shims expose the governance parameters in OZ shape.
    function test_ViewShims_ReturnGovernanceParams() public {
        uint256 proposalId = _proposeDefault();
        IGovernanceState.ProposalWrapper memory wrapper = harness.getProposalById(proposalId);

        assertEq(harness.votingDelay(), 1);
        assertEq(harness.proposalSnapshot(proposalId), wrapper.proposal.startBlockOrTime);
        assertEq(harness.proposalDeadline(proposalId), wrapper.proposal.endBlockOrTime);
        assertEq(harness.proposalProposer(proposalId), whale);
        // no timelock: eta is always 0 and nothing is ever queued
        assertEq(harness.proposalEta(proposalId), 0);
        assertFalse(harness.proposalNeedsQueuing(proposalId));
        assertEq(harness.proposalThreshold(), PROPOSAL_THRESHOLD);
        assertEq(harness.quorum(block.timestamp), QUORUM);
        assertEq(harness.getVotes(whale, block.timestamp), VOTING_POWER);
        assertEq(harness.getVotesWithParams(whale, block.timestamp, hex""), VOTING_POWER);
    }

    /// @notice The OZ abstract-hook views are wired to Rigoblock tallies: quorum counts
    ///     for + against + abstain, success is strictly more for than against.
    function test_OZHooks_ReflectRigoblockTallies() public {
        uint256 againstProposal = _proposeDefault();
        assertFalse(harness.quorumReached(againstProposal));
        assertFalse(harness.voteSucceeded(againstProposal));

        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        harness.castVote(againstProposal, uint8(IGovernanceVoting.VoteType.Against));

        // against votes count toward quorum but can never succeed
        assertTrue(harness.quorumReached(againstProposal));
        assertFalse(harness.voteSucceeded(againstProposal));

        uint256 forProposal = _proposeDefault();
        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        harness.castVote(forProposal, uint8(IGovernanceVoting.VoteType.For));

        assertTrue(harness.quorumReached(forProposal));
        assertTrue(harness.voteSucceeded(forProposal));
    }

    /// @notice The OZ cancel flow resolves the proposal through the stored OZ proposal hash;
    ///     an unknown hash reverts like execute does.
    function test_OZCancel_UnknownHash_Reverts() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(compatTarget);
        calldatas[0] = hex"";

        vm.expectRevert(
            abi.encodeWithSelector(
                MixinVoting.GovProposalIdUnknown.selector,
                bytes32(harness.hashProposal(targets, values, calldatas, keccak256("unknown")))
            )
        );
        harness.cancel(targets, values, calldatas, keccak256("unknown"));
    }

    /// @notice updateThresholds emits the OZ ProposalThresholdSet event for Tally indexing.
    function test_UpdateThresholds_EmitsOZEvent() public {
        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](1);
        actions[0] = IGovernanceVoting.ProposedAction({
            target: address(harness),
            data: abi.encodeWithSelector(IGovernanceUpgrade.updateThresholds.selector, 1, 1),
            value: 0
        });

        uint256 proposalId = _propose(actions, "thresholds");
        _voteAndWarpPast(proposalId, uint8(IGovernanceVoting.VoteType.For));

        vm.expectEmit(true, true, false, true);
        emit IGovernanceEvents.ProposalThresholdSet(1);

        vm.prank(whale);
        harness.execute(proposalId);
        assertEq(harness.proposalThreshold(), 1);
    }

    /// @notice The vendored OZ Governor only exposes the hash-based queue overload
    ///     (there is no queue(uint256)). queue() is doubly disabled in Rigoblock: the
    ///     overridden getProposalId returns the raw content hash, which does not match any
    ///     stored sequential proposal id, so the state check reverts before the timelock
    ///     check (proposalNeedsQueuing is false) could fire GovernorProposalQueueingNotRequired.
    function test_Queue_RevertsQueueingNotRequired() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(compatTarget);
        calldatas[0] = hex"";

        uint256 proposalId = _propose(_toActions(targets, values, calldatas), "oz queue");
        _voteAndWarpPast(proposalId, uint8(IGovernanceVoting.VoteType.For));
        assertEq(uint8(harness.getProposalState(proposalId)), uint8(ProposalStatus.Succeeded));

        bytes32 proposalHash = bytes32(harness.hashProposal(targets, values, calldatas, keccak256("oz queue")));
        vm.expectRevert(abi.encodeWithSelector(MixinAbstract.GovProposalIdInvalid.selector, uint256(proposalHash)));
        harness.queue(targets, values, calldatas, keccak256("oz queue"));
        // silence unused warning, documents that the stored id differs from the content hash
        assertEq(proposalId, 1);
    }

    /// @notice IERC5267: eip712Domain exposes the fixed OZ signing domain used by
    ///     castVoteBySig (name/version bound as immutables, no salt or extensions).
    function test_Eip712Domain_ReturnsFixedDomain() public {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = harness.eip712Domain();

        assertEq(uint8(fields), uint8(0x0f)); // name, version, chainId, verifyingContract
        assertEq(name, "Rigoblock Governance");
        assertEq(version, "1.3.0");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(harness));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    function _toActions(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas
    ) internal pure returns (IGovernanceVoting.ProposedAction[] memory actions) {
        actions = new IGovernanceVoting.ProposedAction[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            actions[i] = IGovernanceVoting.ProposedAction({target: targets[i], data: calldatas[i], value: values[i]});
        }
    }

    function _proposeDefault() internal returns (uint256 proposalId) {
        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](1);
        actions[0] = IGovernanceVoting.ProposedAction({target: address(compatTarget), data: hex"", value: 0});
        return _propose(actions, "proposal");
    }

    function _propose(
        IGovernanceVoting.ProposedAction[] memory actions,
        string memory description
    ) internal returns (uint256 proposalId) {
        vm.prank(whale);
        return harness.propose(actions, description);
    }

    function _voteAndWarpPast(uint256 proposalId, uint8 support) internal {
        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        harness.castVote(proposalId, support);
        IGovernanceState.ProposalWrapper memory wrapper = harness.getProposalById(proposalId);
        vm.warp(wrapper.proposal.endBlockOrTime + 1);
    }
}
