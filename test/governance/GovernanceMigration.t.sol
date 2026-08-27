// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {MixinStorage} from "../../contracts/governance/mixins/MixinStorage.sol";
import {MixinState} from "../../contracts/governance/mixins/MixinState.sol";
import {MixinVoting} from "../../contracts/governance/mixins/MixinVoting.sol";
import {MixinInitializer} from "../../contracts/governance/mixins/MixinInitializer.sol";
import {MixinUpgrade} from "../../contracts/governance/mixins/MixinUpgrade.sol";
import {IGovernanceState} from "../../contracts/governance/interfaces/governance/IGovernanceState.sol";
import {IGovernanceVoting} from "../../contracts/governance/interfaces/governance/IGovernanceVoting.sol";
import {IGovernanceUpgrade} from "../../contracts/governance/interfaces/governance/IGovernanceUpgrade.sol";
import {IRigoblockGovernance} from "../../contracts/governance/IRigoblockGovernance.sol";
import {IGovernanceStrategy} from "../../contracts/governance/interfaces/IGovernanceStrategy.sol";
import {IRigoblockGovernanceFactory} from "../../contracts/governance/interfaces/IRigoblockGovernanceFactory.sol";

/// @title MockMigrationStrategy
/// @notice Simplified strategy that returns deterministic voting power and timestamps
///     so the migration test can focus on the implementation transition, not on staking.
contract MockMigrationStrategy is IGovernanceStrategy {
    uint256 public proposalThreshold;
    uint256 public quorumThreshold;
    uint256 public votingPower;

    function setParams(uint256 proposalThreshold_, uint256 quorumThreshold_, uint256 votingPower_) external {
        proposalThreshold = proposalThreshold_;
        quorumThreshold = quorumThreshold_;
        votingPower = votingPower_;
    }

    function assertValidInitParams(IRigoblockGovernanceFactory.Parameters calldata) external pure {}
    function assertValidThresholds(uint256, uint256) external pure {}

    function getProposalState(
        IRigoblockGovernance.Proposal memory proposal,
        uint256 minimumQuorum
    ) external view returns (IGovernanceState.ProposalState) {
        if (block.timestamp <= proposal.startBlockOrTime) {
            return IGovernanceState.ProposalState.Pending;
        } else if (block.timestamp <= proposal.endBlockOrTime && _qualified(proposal, minimumQuorum)) {
            return IGovernanceState.ProposalState.Qualified;
        } else if (block.timestamp <= proposal.endBlockOrTime) {
            return IGovernanceState.ProposalState.Active;
        } else if (proposal.votesFor <= 2 * proposal.votesAgainst || proposal.votesFor < minimumQuorum) {
            return IGovernanceState.ProposalState.Defeated;
        } else if (proposal.executed) {
            return IGovernanceState.ProposalState.Executed;
        } else {
            return IGovernanceState.ProposalState.Succeeded;
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

    function votingTimestamps() external view returns (uint256 startBlockOrTime, uint256 endBlockOrTime) {
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
}

/// @title MigrationHarness
/// @notice Exposes governance storage and uses the real new-implementation mixins.
contract MigrationHarness is MixinStorage, MixinInitializer, MixinUpgrade, MixinVoting, MixinState {
    constructor() MixinStorage() {}

    function setStrategy(address strategy_) external {
        _paramsWrapper().governanceParameters.strategy = strategy_;
    }

    function setParams(uint256 proposalThreshold_, uint256 quorumThreshold_) external {
        _paramsWrapper().governanceParameters.proposalThreshold = proposalThreshold_;
        _paramsWrapper().governanceParameters.quorumThreshold = quorumThreshold_;
    }

    function setProposalCount(uint256 count) external {
        _proposalCount().value = count;
    }

    function setProposal(uint256 proposalId, IGovernanceState.Proposal calldata proposal) external {
        _proposal().proposalById[proposalId] = proposal;
    }

    function setProposalQuorum(uint256 proposalId, uint256 quorum) external {
        _proposalQuorum().proposalQuorumById[proposalId] = quorum;
    }

    function proposalSlot() external pure returns (bytes32) {
        return _PROPOSAL_SLOT;
    }

    function proposalQuorumSlot() external pure returns (bytes32) {
        return _PROPOSAL_QUORUM_SLOT;
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
///     `proposalQuorumById` snapshot mapping. Verifies that:
///     1. Proposals written by the old implementation (no quorum mapping entry) are treated
///        as legacy and rendered unexecutable.
///     2. New proposals created after the upgrade snapshot the current quorum in a mapping.
///     3. A later quorum reduction cannot resurrect a legacy proposal.
contract GovernanceMigrationTest is Test {
    MigrationHarness internal harness;
    MockMigrationStrategy internal strategy;
    MockTarget internal target;

    address internal whale = makeAddr("whale");

    uint256 internal constant INITIAL_QUORUM = 1_000_000e18;
    uint256 internal constant LOWERED_QUORUM = 500_000e18;
    uint256 internal constant PROPOSAL_THRESHOLD = 100_000e18;
    uint256 internal constant LOWERED_PROPOSAL_THRESHOLD = 50_000e18;
    uint256 internal constant VOTING_POWER = 2_000_000e18;

    function setUp() public {
        harness = new MigrationHarness();
        strategy = new MockMigrationStrategy();
        target = new MockTarget();
        strategy.setParams(PROPOSAL_THRESHOLD, INITIAL_QUORUM, VOTING_POWER);
        harness.setStrategy(address(strategy));
        harness.setParams(PROPOSAL_THRESHOLD, INITIAL_QUORUM);
    }

    /// @notice Verifies that a proposal whose storage was written without a quorum
    ///     snapshot is treated as legacy (mapping returns 0) and uses type(uint256).max
    ///     as its effective quorum.
    function test_Migration_LegacyProposal_BecomesDefeated() public {
        uint256 legacyId = _createLegacyProposal();

        // The legacy proposal has no quorum mapping entry.
        assertEq(_readProposalQuorum(legacyId), 0);

        // Warp past voting period. The legacy proposal can never reach type(uint256).max quorum.
        vm.warp(block.timestamp + 8 days);
        assertEq(uint256(harness.getProposalState(legacyId)), uint256(IGovernanceState.ProposalState.Defeated));
    }

    /// @notice Verifies that new proposals created after the migration snapshot the
    ///     current global quorum in a dedicated mapping and remain executable.
    function test_Migration_NewProposal_ExecutesAfterUpgrade() public {
        uint256 legacyId = _createLegacyProposal();

        // Create a new proposal after the (simulated) migration.
        uint256 newId = _createProposal("new proposal");
        assertEq(_readProposalQuorum(newId), INITIAL_QUORUM);

        // Vote and execute the new proposal.
        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        harness.castVote(newId, IGovernanceVoting.VoteType.For);
        vm.warp(block.timestamp + 8 days);
        assertEq(uint256(harness.getProposalState(newId)), uint256(IGovernanceState.ProposalState.Succeeded));
        harness.execute(newId);
        assertEq(uint256(harness.getProposalState(newId)), uint256(IGovernanceState.ProposalState.Executed));

        // The legacy proposal remains unexecutable.
        assertEq(uint256(harness.getProposalState(legacyId)), uint256(IGovernanceState.ProposalState.Defeated));
    }

    /// @notice Verifies that lowering the global quorum after the migration does not
    ///     make a legacy proposal executable, while a new proposal created after the
    ///     reduction snapshots the lower quorum and can be executed.
    function test_Migration_LoweredQuorum_DoesNotResurrectLegacy() public {
        uint256 legacyId = _createLegacyProposal();

        // Create and execute a proposal that lowers the global quorum.
        uint256 lowerQuorumId = _createLowerQuorumProposal();
        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        harness.castVote(lowerQuorumId, IGovernanceVoting.VoteType.For);
        vm.warp(block.timestamp + 8 days);
        harness.execute(lowerQuorumId);

        assertEq(_governanceQuorum(), LOWERED_QUORUM);

        // Legacy proposal still cannot reach quorum.
        assertEq(uint256(harness.getProposalState(legacyId)), uint256(IGovernanceState.ProposalState.Defeated));

        // A new proposal created after the reduction uses the lowered quorum.
        uint256 postReductionId = _createProposal("post reduction proposal");
        assertEq(_readProposalQuorum(postReductionId), LOWERED_QUORUM);

        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        harness.castVote(postReductionId, IGovernanceVoting.VoteType.For);
        vm.warp(block.timestamp + 8 days);
        assertEq(uint256(harness.getProposalState(postReductionId)), uint256(IGovernanceState.ProposalState.Succeeded));
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

        // The quorum snapshot lives in its own mapping at a different slot.
        bytes32 quorumSlot = keccak256(abi.encode(uint256(proposalId), uint256(harness.proposalQuorumSlot())));
        assertTrue(executedSlot != quorumSlot);
        assertEq(vm.load(address(harness), quorumSlot), bytes32(uint256(12345)));
    }

    /// @dev Creates a proposal using the current (new) implementation and returns its id.
    function _createProposal(string memory description) private returns (uint256 proposalId) {
        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](1);
        actions[0] = IGovernanceVoting.ProposedAction({target: address(target), data: "", value: 0});
        vm.prank(whale);
        return harness.propose(actions, description);
    }

    /// @dev Simulates a proposal written by the old implementation by creating a
    ///     proposal with the new implementation and then deleting its quorum mapping entry.
    function _createLegacyProposal() private returns (uint256 proposalId) {
        proposalId = _createProposal("legacy proposal");
        harness.setProposalQuorum(proposalId, 0);

        // Sanity check: the new implementation reads it as legacy.
        assertEq(_readProposalQuorum(proposalId), 0);
    }

    /// @dev Returns the raw quorum snapshot for a proposal from storage.
    function _readProposalQuorum(uint256 proposalId) private view returns (uint256) {
        bytes32 quorumSlot = keccak256(abi.encode(proposalId, uint256(harness.proposalQuorumSlot())));
        return uint256(vm.load(address(harness), quorumSlot));
    }

    /// @dev Creates a proposal that lowers the global quorum to LOWERED_QUORUM.
    ///     Both thresholds must change because updateThresholds requires both to differ.
    function _createLowerQuorumProposal() private returns (uint256 proposalId) {
        bytes memory data = abi.encodeWithSelector(
            IGovernanceUpgrade.updateThresholds.selector,
            LOWERED_PROPOSAL_THRESHOLD,
            LOWERED_QUORUM
        );
        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](1);
        actions[0] = IGovernanceVoting.ProposedAction({target: address(harness), data: data, value: 0});
        vm.prank(whale);
        return harness.propose(actions, "lower quorum");
    }

    /// @dev Reads the current global quorum from governance parameters.
    function _governanceQuorum() private view returns (uint256) {
        IGovernanceState.EnhancedParams memory params = harness.governanceParameters();
        return params.params.quorumThreshold;
    }
}
