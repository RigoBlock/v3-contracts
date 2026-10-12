// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {ProposalStatus, ProposedAction} from "../../contracts/governance/types/GovernanceTypes.sol";
import {Test} from "forge-std/Test.sol";
import {MixinCrosschain} from "../../contracts/governance/mixins/MixinCrosschain.sol";
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
import {TimeType} from "../../contracts/governance/types/TimeType.sol";
import {IGovernor as IOZGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IGovernor as OZGovernorV5} from "@openzeppelin-gov/governance/IGovernor.sol";

/// @title MockMigrationStrategy
/// @notice Simplified strategy that returns deterministic voting power and timestamps
///     so the migration test can focus on the implementation transition, not on staking.
///     Threshold updates are validated in beforePropose, mirroring the sender strategy.
contract MockMigrationStrategy is IGovernanceStrategy {
    /// @notice Marker errors proving a threshold validation was invoked.
    error MockInvalidProposalThreshold();
    error MockInvalidQuorumThreshold();

    /// @dev Voting period in blocks for block mode, i.e. 7 days at ~12s blocks. Must be
    ///      denominated in blocks: the timestamp period (7 days) is expressed in seconds and
    ///      cannot be added to a block number without corrupting the window.
    uint256 public constant BLOCK_VOTING_PERIOD = 50_400;

    uint256 public proposalThreshold;
    uint256 public quorumThreshold;
    uint256 public votingPower;
    /// @dev Window unit: an integrator strategy knows its governance's TimeType at deploy time.
    bool public blockMode;

    bool private immutable _revertOnProposalValidation;
    bool private immutable _revertOnQuorumValidation;

    constructor(bool revertOnProposalValidation, bool revertOnQuorumValidation) {
        _revertOnProposalValidation = revertOnProposalValidation;
        _revertOnQuorumValidation = revertOnQuorumValidation;
    }

    function setParams(uint256 proposalThreshold_, uint256 quorumThreshold_, uint256 votingPower_) external {
        proposalThreshold = proposalThreshold_;
        quorumThreshold = quorumThreshold_;
        votingPower = votingPower_;
    }

    function setBlockMode(bool blockMode_) external {
        blockMode = blockMode_;
    }

    function validateParams(IRigoblockGovernanceFactory.Parameters calldata) external pure {}

    function getProposalState(
        IRigoblockGovernance.Proposal memory proposal,
        address,
        uint256 minimumQuorum,
        uint256,
        TimeType timeType
    ) external view returns (ProposalStatus) {
        // executed is terminal and must be reported regardless of the clock
        if (proposal.executed) return ProposalStatus.Executed;
        uint256 blockOrTime = timeType == TimeType.Timestamp ? block.timestamp : block.number;
        if (blockOrTime <= proposal.startBlockOrTime) {
            return ProposalStatus.Pending;
        } else if (blockOrTime <= proposal.endBlockOrTime && _qualified(proposal, minimumQuorum)) {
            return ProposalStatus.Qualified;
        } else if (blockOrTime <= proposal.endBlockOrTime) {
            return ProposalStatus.Active;
        } else if (proposal.votesFor <= 2 * proposal.votesAgainst || proposal.votesFor < minimumQuorum) {
            return ProposalStatus.Defeated;
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

    function getVotingPower(address) external view returns (uint256) {
        return votingPower;
    }

    function beforePropose(
        ProposedAction[] calldata actions
    ) external view returns (ProposedAction[] memory, uint256 startBlockOrTime, uint256 endBlockOrTime) {
        // threshold updates are validated here, at propose time; a flag that rejects a changed
        // threshold must not block an update that leaves it unchanged
        for (uint256 i = 0; i < actions.length; i++) {
            if (actions[i].target != msg.sender || actions[i].data.length < 4) continue;
            if (bytes4(actions[i].data) != IGovernanceUpgrade.updateThresholds.selector) continue;
            (uint256 newProposalThreshold, uint256 newQuorumThreshold) = abi.decode(
                actions[i].data[4:],
                (uint256, uint256)
            );
            require(
                !_revertOnProposalValidation || newProposalThreshold == proposalThreshold,
                MockInvalidProposalThreshold()
            );
            require(!_revertOnQuorumValidation || newQuorumThreshold == quorumThreshold, MockInvalidQuorumThreshold());
        }
        startBlockOrTime = blockMode ? block.number + 1 : block.timestamp + 1;
        endBlockOrTime = startBlockOrTime + (blockMode ? BLOCK_VOTING_PERIOD : 7 days);
        return (actions, startBlockOrTime, endBlockOrTime);
    }

    function beforeVote() external view returns (uint256) {
        return votingPower;
    }

    function beforeExecute(ProposedAction[] calldata actions) external pure returns (ProposedAction[] memory) {
        return actions;
    }

    function wormhole() external pure returns (address) {
        return address(0);
    }
}

/// @title MigrationHarness
/// @notice Exposes governance storage and uses the real new-implementation mixins.
contract MigrationHarness is MixinStorage, MixinInitializer, MixinVoting, MixinUpgrade, MixinCrosschain {
    // 2 is the Wormhole chain id of Ethereum, the governance hub
    constructor() MixinStorage(2) {}

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

    function setProposalCount(uint256 count) external {
        _proposalCount().value = count;
    }

    function setProposal(uint256 proposalId, IGovernanceState.Proposal calldata proposal) external {
        _proposal().proposalById[proposalId] = proposal;
    }

    function setProposalQuorum(uint256 proposalId, uint256 quorum) external {
        _proposalExtraData().proposalExtraDataById[proposalId].quorum = uint128(quorum);
    }

    function proposalSlot() external pure returns (bytes32) {
        return _PROPOSAL_SLOT;
    }

    function proposalExtraDataSlot() external pure returns (bytes32) {
        return _PROPOSAL_EXTRA_DATA_SLOT;
    }

    function proposalMetaSlot() external pure returns (bytes32) {
        return _PROPOSAL_META_SLOT;
    }

    function proposalCountSlot() external pure returns (bytes32) {
        return _PROPOSAL_COUNT_SLOT;
    }

    function governanceParamsSlot() external pure returns (bytes32) {
        return _GOVERNANCE_PARAMS_SLOT;
    }

    function implementationSlot() external pure returns (bytes32) {
        return _IMPLEMENTATION_SLOT;
    }
}

/// @title MockTarget
/// @notice No-op call target for proposal execution tests.
contract MockTarget {
    fallback() external {}
}

/// @title GovernanceMigrationTest
/// @notice Simulates the governance implementation upgrade that introduces the
///     merged proposal extra-data slot (quorum snapshot). Verifies that:
///     1. Proposals written by the old implementation (no quorum snapshot) are treated
///        as legacy and rendered unexecutable.
///     2. New proposals created after the upgrade snapshot the current quorum in a mapping.
///     3. A later quorum reduction cannot resurrect a legacy proposal.
contract GovernanceMigrationTest is Test {
    MigrationHarness internal harness;
    MockMigrationStrategy internal strategy;
    MockTarget internal target;

    address internal whale = makeAddr("whale");

    // initialization parameters served to the RigoblockGovernanceProxy constructor, which reads
    // them from msg.sender (this test contract, when the proxy is deployed via deployCode)
    IRigoblockGovernanceFactory.Parameters internal _proxyParams;

    /// @notice Returns the parameters used to initialize a freshly deployed governance proxy.
    function parameters() external view returns (IRigoblockGovernanceFactory.Parameters memory) {
        return _proxyParams;
    }

    uint256 internal constant INITIAL_QUORUM = 1_000_000e18;
    uint256 internal constant LOWERED_QUORUM = 500_000e18;
    uint256 internal constant PROPOSAL_THRESHOLD = 100_000e18;
    uint256 internal constant LOWERED_PROPOSAL_THRESHOLD = 50_000e18;
    uint256 internal constant VOTING_POWER = 2_000_000e18;

    function setUp() public {
        harness = new MigrationHarness();
        strategy = new MockMigrationStrategy(false, false);
        target = new MockTarget();
        strategy.setParams(PROPOSAL_THRESHOLD, INITIAL_QUORUM, VOTING_POWER);
        harness.setStrategy(address(strategy));
        harness.setParams(PROPOSAL_THRESHOLD, INITIAL_QUORUM);
        harness.setTimeType(TimeType.Timestamp);
    }

    /// @notice Verifies that a proposal whose storage was written without a quorum
    ///     snapshot is treated as legacy (mapping returns 0) and uses type(uint256).max
    ///     as its effective quorum.
    function test_Migration_LegacyProposal_BecomesDefeated() public {
        uint256 legacyId = _createLegacyProposal(harness);

        // The legacy proposal has no quorum snapshot.
        assertEq(_readProposalQuorum(harness, legacyId), 0);

        // Warp past voting period. The legacy proposal can never reach type(uint256).max quorum.
        vm.warp(block.timestamp + 8 days);
        assertEq(uint256(harness.getProposalState(legacyId)), uint256(ProposalStatus.Defeated));
    }

    /// @notice Verifies that new proposals created after the migration snapshot the
    ///     current global quorum in a dedicated mapping and remain executable.
    function test_Migration_NewProposal_ExecutesAfterUpgrade() public {
        uint256 legacyId = _createLegacyProposal(harness);

        // Create a new proposal after the (simulated) migration.
        uint256 newId = _createProposal(harness, "new proposal");
        assertEq(_readProposalQuorum(harness, newId), INITIAL_QUORUM);

        // Vote and execute the new proposal.
        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        harness.castVote(newId, uint8(IGovernanceVoting.VoteType.For));
        vm.warp(block.timestamp + 8 days);
        assertEq(uint256(harness.getProposalState(newId)), uint256(ProposalStatus.Succeeded));
        harness.execute(newId);
        assertEq(uint256(harness.getProposalState(newId)), uint256(ProposalStatus.Executed));

        // The legacy proposal remains unexecutable.
        assertEq(uint256(harness.getProposalState(legacyId)), uint256(ProposalStatus.Defeated));
    }

    /// @notice Runs a full proposal lifecycle through a real governance proxy (harness as
    ///     implementation) and asserts the OZ Governor, EIP712 and Nonces linear slots 0..8
    ///     are never written.
    function test_Migration_OzLinearSlots_StayZeroThroughLifecycle() public {
        // the proxy constructor and initializer read the parameters from msg.sender, which is
        // this test contract when deploying via deployCode (0.8.17 artifact, cannot be imported)
        _proxyParams = IRigoblockGovernanceFactory.Parameters({
            implementation: address(harness),
            governanceStrategy: address(strategy),
            proposalThreshold: PROPOSAL_THRESHOLD,
            quorumThreshold: INITIAL_QUORUM,
            timeType: TimeType.Timestamp,
            name: "Rigoblock Governance"
        });
        MigrationHarness proxy = MigrationHarness(
            payable(deployCode("out/RigoblockGovernanceProxy.sol/RigoblockGovernanceProxy.json"))
        );

        uint256 proposalId = _createProposal(proxy, "proxy lifecycle proposal");
        _voteAndExecute(proxy, proposalId);
        assertEq(uint256(proxy.getProposalState(proposalId)), uint256(ProposalStatus.Executed));

        // OZ Governor/EIP712/Nonces linear slots: must stay dead as lifecycle overrides never call super.
        for (uint256 slot; slot <= 8; ++slot) {
            assertEq(vm.load(address(proxy), bytes32(slot)), bytes32(0));
        }
    }

    /// @notice Verifies that lowering the global quorum after the migration does not
    ///     make a legacy proposal executable, while a new proposal created after the
    ///     reduction snapshots the lower quorum and can be executed.
    function test_Migration_LoweredQuorum_DoesNotResurrectLegacy() public {
        uint256 legacyId = _createLegacyProposal(harness);

        // Create and execute a proposal that lowers the global quorum.
        uint256 lowerQuorumId = _createLowerQuorumProposal(harness);
        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        harness.castVote(lowerQuorumId, uint8(IGovernanceVoting.VoteType.For));
        vm.warp(block.timestamp + 8 days);
        harness.execute(lowerQuorumId);

        assertEq(_governanceQuorum(), LOWERED_QUORUM);

        // Legacy proposal still cannot reach quorum.
        assertEq(uint256(harness.getProposalState(legacyId)), uint256(ProposalStatus.Defeated));

        // A new proposal created after the reduction uses the lowered quorum.
        uint256 postReductionId = _createProposal(harness, "post reduction proposal");
        assertEq(_readProposalQuorum(harness, postReductionId), LOWERED_QUORUM);

        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        harness.castVote(postReductionId, uint8(IGovernanceVoting.VoteType.For));
        vm.warp(block.timestamp + 8 days);
        assertEq(uint256(harness.getProposalState(postReductionId)), uint256(ProposalStatus.Succeeded));
    }

    /// @notice Threshold updates are validated by the strategy's beforePropose hook, at
    ///     propose time: a strategy that rejects a changed proposal threshold must not block
    ///     an update that leaves it unchanged, while a proposal changing it reverts at propose.
    function test_UpdateThresholds_ValidatedAtProposeTime() public {
        // a strategy that rejects any NEW proposal threshold: a quorum-only update must still
        // succeed, because the unchanged proposal threshold is not flagged
        MockMigrationStrategy rejectingProposal = new MockMigrationStrategy(true, false);
        rejectingProposal.setParams(PROPOSAL_THRESHOLD, INITIAL_QUORUM, VOTING_POWER);
        harness.setStrategy(address(rejectingProposal));
        bytes memory quorumOnly = abi.encodeWithSelector(
            IGovernanceUpgrade.updateThresholds.selector,
            PROPOSAL_THRESHOLD,
            LOWERED_QUORUM
        );
        uint256 quorumOnlyId = _createProposalWithData(harness, quorumOnly, "quorum only");
        _voteAndExecute(harness, quorumOnlyId);
        assertEq(_governanceQuorum(), LOWERED_QUORUM);

        // an update that changes the proposal threshold is validated and reverts at propose
        bytes memory both = abi.encodeWithSelector(
            IGovernanceUpgrade.updateThresholds.selector,
            LOWERED_PROPOSAL_THRESHOLD,
            LOWERED_QUORUM
        );
        vm.expectRevert(MockMigrationStrategy.MockInvalidProposalThreshold.selector);
        _createProposalWithData(harness, both, "both thresholds");

        // symmetric case: a strategy rejecting any new quorum must not block a proposal-only
        // update; the mock's notion of the current quorum is synced to the value the earlier
        // quorum-only proposal stored
        MockMigrationStrategy rejectingQuorum = new MockMigrationStrategy(false, true);
        rejectingQuorum.setParams(PROPOSAL_THRESHOLD, LOWERED_QUORUM, VOTING_POWER);
        harness.setStrategy(address(rejectingQuorum));

        // a proposal that changes the quorum is validated and reverts at propose
        bytes memory changedQuorum = abi.encodeWithSelector(
            IGovernanceUpgrade.updateThresholds.selector,
            PROPOSAL_THRESHOLD,
            INITIAL_QUORUM
        );
        vm.expectRevert(MockMigrationStrategy.MockInvalidQuorumThreshold.selector);
        _createProposalWithData(harness, changedQuorum, "changed quorum");

        bytes memory proposalOnly = abi.encodeWithSelector(
            IGovernanceUpgrade.updateThresholds.selector,
            LOWERED_PROPOSAL_THRESHOLD,
            LOWERED_QUORUM
        );
        uint256 proposalOnlyId = _createProposalWithData(harness, proposalOnly, "proposal only");
        _voteAndExecute(harness, proposalOnlyId);

        IGovernanceState.EnhancedParams memory params = harness.governanceParameters();
        assertEq(params.params.proposalThreshold, LOWERED_PROPOSAL_THRESHOLD);
        assertEq(params.params.quorumThreshold, LOWERED_QUORUM);
    }

    /// @notice A proposer can cancel their own proposal while it is still Pending, after which
    ///     it reads as Canceled and neither votes nor execution are possible anymore.
    function test_Cancel_ProposerWhilePending_Succeeds() public {
        uint256 proposalId = _createProposal(harness, "cancelable proposal");
        assertEq(uint256(harness.getProposalState(proposalId)), uint256(ProposalStatus.Pending));
        assertEq(harness.proposalProposer(proposalId), whale);

        vm.expectEmit(true, false, false, true);
        emit IOZGovernor.ProposalCanceled(proposalId);
        vm.prank(whale);
        harness.cancel(proposalId);

        assertEq(uint256(harness.getProposalState(proposalId)), uint256(ProposalStatus.Canceled));

        // voting and executing a canceled proposal must revert. The vote path is OZ's
        // `castVote`, which validates state before counting and reverts with the OZ error.
        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        vm.expectRevert(
            abi.encodeWithSelector(
                OZGovernorV5.GovernorUnexpectedProposalState.selector,
                proposalId,
                OZGovernorV5.ProposalState.Canceled,
                bytes32(uint256(1 << uint8(OZGovernorV5.ProposalState.Active)))
            )
        );
        harness.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));

        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(
            abi.encodeWithSelector(MixinVoting.GovVotingClosed.selector, proposalId, ProposalStatus.Canceled)
        );
        harness.execute(proposalId);
    }

    /// @notice An account that did not create the proposal cannot cancel it. The proposer
    ///     themselves can cancel the very same proposal, proving the check is on the creator
    ///     and not on voting power.
    function test_Cancel_NonProposer_Reverts() public {
        uint256 proposalId = _createProposal(harness, "not yours");
        address other = makeAddr("other");
        vm.expectRevert(abi.encodeWithSelector(MixinVoting.GovUnableToCancel.selector, proposalId, other));
        vm.prank(other);
        harness.cancel(proposalId);

        assertEq(uint256(harness.getProposalState(proposalId)), uint256(ProposalStatus.Pending));

        // the proposer retains the right to cancel what they created
        vm.prank(whale);
        harness.cancel(proposalId);
        assertEq(uint256(harness.getProposalState(proposalId)), uint256(ProposalStatus.Canceled));
    }

    /// @notice Cancellation is only possible while the proposal is Pending: once voting has
    ///     started (or the proposal is over), the proposer can no longer retract it.
    function test_Cancel_AfterVotingStarts_Reverts() public {
        uint256 proposalId = _createProposal(harness, "already active");

        // an Against vote keeps the proposal Active (a For vote would qualify it)
        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        harness.castVote(proposalId, uint8(IGovernanceVoting.VoteType.Against));
        assertEq(uint256(harness.getProposalState(proposalId)), uint256(ProposalStatus.Active));

        vm.expectRevert(
            abi.encodeWithSelector(MixinVoting.GovVotingClosed.selector, proposalId, ProposalStatus.Active)
        );
        vm.prank(whale);
        harness.cancel(proposalId);
        assertEq(uint256(harness.getProposalState(proposalId)), uint256(ProposalStatus.Active));

        // also not after the voting period has ended
        vm.warp(block.timestamp + 8 days);
        assertEq(uint256(harness.getProposalState(proposalId)), uint256(ProposalStatus.Defeated));
        vm.expectRevert(
            abi.encodeWithSelector(MixinVoting.GovVotingClosed.selector, proposalId, ProposalStatus.Defeated)
        );
        vm.prank(whale);
        harness.cancel(proposalId);
        assertEq(uint256(harness.getProposalState(proposalId)), uint256(ProposalStatus.Defeated));
    }

    /// @notice A proposal created before the cancel feature existed (no recorded proposer in
    ///     storage) cannot be canceled by anyone: the zero-address proposer check blocks
    ///     cancellation instead of letting address(0) cancel.
    function test_Cancel_LegacyProposal_HasNoProposer() public {
        uint256 legacyId = _createLegacyProposal(harness);

        // simulate the old implementation, which never wrote the proposer: clear the meta slot
        bytes32 metaSlot = keccak256(abi.encode(uint256(legacyId), uint256(harness.proposalMetaSlot())));
        vm.store(address(harness), metaSlot, bytes32(0));
        assertEq(harness.proposalProposer(legacyId), address(0));

        vm.expectRevert(abi.encodeWithSelector(MixinVoting.GovUnableToCancel.selector, legacyId, whale));
        vm.prank(whale);
        harness.cancel(legacyId);
        assertEq(uint256(harness.getProposalState(legacyId)), uint256(ProposalStatus.Pending));
    }

    /// @notice Canceling one proposal must not leak into other proposals' meta or state.
    function test_Cancel_IsolatedPerProposal() public {
        uint256 first = _createProposal(harness, "first");
        uint256 second = _createProposal(harness, "second");

        vm.prank(whale);
        harness.cancel(first);

        assertEq(uint256(harness.getProposalState(first)), uint256(ProposalStatus.Canceled));
        assertEq(harness.proposalProposer(second), whale);
        assertEq(uint256(harness.getProposalState(second)), uint256(ProposalStatus.Pending));

        // the surviving proposal remains fully executable
        _voteAndExecute(harness, second);
        assertEq(uint256(harness.getProposalState(second)), uint256(ProposalStatus.Executed));
    }

    /// @notice Exercises the view getters getActions, getReceipt and proposals against a
    ///     proposal created and voted on through the normal propose/castVote flow.
    function test_Getters_ReturnProposalActionsAndReceipt() public {
        uint256 proposalId = _createProposal(harness, "getter proposal");
        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        harness.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));

        ProposedAction[] memory actions = harness.getActions(proposalId);
        assertEq(actions.length, 1);
        assertEq(actions[0].target, address(target));
        assertEq(actions[0].value, 0);

        IGovernanceState.Receipt memory receipt = harness.getReceipt(proposalId, whale);
        assertTrue(receipt.hasVoted);
        assertEq(uint256(receipt.voteType), uint256(IGovernanceVoting.VoteType.For));
        assertEq(receipt.votes, VOTING_POWER);
        IGovernanceState.Receipt memory noReceipt = harness.getReceipt(proposalId, makeAddr("nonVoter"));
        assertFalse(noReceipt.hasVoted);

        IGovernanceState.ProposalWrapper[] memory allProposals = harness.proposals();
        assertEq(allProposals.length, 1);
        assertEq(allProposals[0].proposal.actionsLength, 1);
        assertEq(allProposals[0].proposedAction.length, 1);
        assertEq(allProposals[0].proposedAction[0].target, address(target));
    }

    /// @notice Stores a proposal through the harness and then reads the underlying
    ///     storage slots to prove that the Proposal struct and the quorum snapshot mapping
    ///     live in disjoint storage locations.
    function test_Migration_StorageLayout_ProposalAndQuorumAreDisjoint() public {
        uint256 proposalId = 1;

        IGovernanceState.Proposal memory proposal = IGovernanceState.Proposal({
            actionsLength: 3,
            startBlockOrTime: 100,
            endBlockOrTime: 200,
            votesFor: 10,
            votesAgainst: 5,
            votesAbstain: 1,
            executed: true
        });
        harness.setProposal(proposalId, proposal);
        harness.setProposalQuorum(proposalId, 12345);
        harness.setProposalCount(1);

        IGovernanceState.ProposalWrapper memory wrapper = harness.getProposalById(proposalId);
        assertEq(wrapper.proposal.actionsLength, 3);
        assertEq(wrapper.proposal.startBlockOrTime, 100);
        assertEq(wrapper.proposal.endBlockOrTime, 200);
        assertEq(wrapper.proposal.votesFor, 10);
        assertEq(wrapper.proposal.votesAgainst, 5);
        assertEq(wrapper.proposal.votesAbstain, 1);
        assertEq(wrapper.proposal.executed, true);

        bytes32 proposalBaseSlot = keccak256(abi.encode(uint256(proposalId), uint256(harness.proposalSlot())));
        bytes32 executedSlot = bytes32(uint256(proposalBaseSlot) + 6);

        // `executed` is the last field of the 7-field Proposal struct.
        assertEq(vm.load(address(harness), executedSlot), bytes32(uint256(1)));

        // The quorum snapshot lives in its own mapping at a different slot, packed with the
        // first-vote voting-power snapshot as two uint128 in one slot value.
        bytes32 quorumSlot = keccak256(abi.encode(uint256(proposalId), uint256(harness.proposalExtraDataSlot())));
        assertTrue(executedSlot != quorumSlot);
        assertEq(vm.load(address(harness), quorumSlot), bytes32(uint256(12345)));
    }

    /// @dev Creates a proposal on the given instance and returns its id.
    function _createProposal(
        MigrationHarness instance,
        string memory description
    ) private returns (uint256 proposalId) {
        ProposedAction[] memory actions = new ProposedAction[](1);
        actions[0] = ProposedAction({target: address(target), data: "", value: 0});
        vm.prank(whale);
        return instance.propose(actions, description);
    }

    /// @dev Simulates a proposal written by the old implementation by creating a
    ///     proposal with the new implementation and then deleting its quorum snapshot.
    function _createLegacyProposal(MigrationHarness instance) private returns (uint256 proposalId) {
        proposalId = _createProposal(instance, "legacy proposal");
        instance.setProposalQuorum(proposalId, 0);

        // Sanity check: the new implementation reads it as legacy.
        assertEq(_readProposalQuorum(instance, proposalId), 0);
    }

    /// @dev Returns the raw quorum snapshot for a proposal from storage.
    function _readProposalQuorum(MigrationHarness instance, uint256 proposalId) private view returns (uint256) {
        bytes32 extraDataSlot = keccak256(abi.encode(proposalId, uint256(instance.proposalExtraDataSlot())));
        return uint128(uint256(vm.load(address(instance), extraDataSlot)));
    }

    /// @dev Creates a proposal whose single action calls the given instance with the given calldata.
    function _createProposalWithData(
        MigrationHarness instance,
        bytes memory data,
        string memory description
    ) private returns (uint256 proposalId) {
        ProposedAction[] memory actions = new ProposedAction[](1);
        actions[0] = ProposedAction({target: address(instance), data: data, value: 0});
        vm.prank(whale);
        return instance.propose(actions, description);
    }

    /// @dev Votes for and executes a proposal after its voting period.
    function _voteAndExecute(MigrationHarness instance, uint256 proposalId) private {
        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        instance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        vm.warp(block.timestamp + 8 days);
        instance.execute(proposalId);
    }

    /// @dev Creates a proposal that lowers the global quorum to LOWERED_QUORUM.
    ///     The proposal threshold is updated alongside, as updateThresholds reverts
    ///     only when both thresholds are unchanged.
    function _createLowerQuorumProposal(MigrationHarness instance) private returns (uint256 proposalId) {
        bytes memory data = abi.encodeWithSelector(
            IGovernanceUpgrade.updateThresholds.selector,
            LOWERED_PROPOSAL_THRESHOLD,
            LOWERED_QUORUM
        );
        return _createProposalWithData(instance, data, "lower quorum");
    }

    /// @dev Reads the current global quorum from governance parameters.
    function _governanceQuorum() private view returns (uint256) {
        IGovernanceState.EnhancedParams memory params = harness.governanceParameters();
        return params.params.quorumThreshold;
    }
}
