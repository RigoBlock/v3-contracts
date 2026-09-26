// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {MigrationHarness, MockMigrationStrategy, MockTarget} from "./GovernanceMigration.t.sol";
import {MixinVoting} from "../../contracts/governance/mixins/MixinVoting.sol";
import {IGovernanceState} from "../../contracts/governance/interfaces/governance/IGovernanceState.sol";
import {IGovernanceUpgrade} from "../../contracts/governance/interfaces/governance/IGovernanceUpgrade.sol";
import {IGovernanceEvents} from "../../contracts/governance/interfaces/governance/IGovernanceEvents.sol";
import {IGovernanceVoting} from "../../contracts/governance/interfaces/governance/IGovernanceVoting.sol";
import {TimeType} from "../../contracts/governance/types/TimeType.sol";

/// @title QualifyAndExecute
/// @notice Bundles castVote + execute in a single transaction to prove a qualified
///     proposal cannot be executed in the same transaction that qualified it.
contract QualifyAndExecute {
    function qualifyAndExecute(address governance, uint256 proposalId) external {
        IGovernanceVoting(governance).castVote(proposalId, IGovernanceVoting.VoteType.For);
        IGovernanceVoting(governance).execute(proposalId);
    }
}

/// @title GovernanceTimeTypeTest
/// @notice Verifies that governance voting lifecycles are correct for both TimeType
///     values: a qualified proposal becomes executable only in a later block (Blocknumber)
///     or a later timestamp (Timestamp), never in the qualifying transaction itself.
contract GovernanceTimeTypeTest is Test {
    MigrationHarness internal harness;
    MockMigrationStrategy internal strategy;
    MockTarget internal target;
    QualifyAndExecute internal bundler;

    address internal whale = makeAddr("whale");

    uint256 internal constant PROPOSAL_THRESHOLD = 100_000e18;
    uint256 internal constant QUORUM_THRESHOLD = 1_000_000e18;
    uint256 internal constant LOWERED_QUORUM = 600_000e18;
    uint256 internal constant VOTING_POWER = 2_000_000e18;

    function setUp() public {
        harness = new MigrationHarness();
        strategy = new MockMigrationStrategy(false, false);
        target = new MockTarget();
        bundler = new QualifyAndExecute();
        strategy.setParams(PROPOSAL_THRESHOLD, QUORUM_THRESHOLD, VOTING_POWER);
        harness.setStrategy(address(strategy));
        harness.setParams(PROPOSAL_THRESHOLD, QUORUM_THRESHOLD);
    }

    /// @notice A proposal qualified in Blocknumber mode closes voting at the qualifying
    ///     block and can be executed from the next block on.
    function test_Blocknumber_QualifiedProposal_ExecutesNextBlock() public {
        harness.setTimeType(TimeType.Blocknumber);
        uint256 proposalId = _createProposal();

        // voting starts at block.number + 1
        IGovernanceState.ProposalWrapper memory wrapper = harness.getProposalById(proposalId);
        assertEq(wrapper.proposal.startBlockOrTime, block.number + 1);

        // pass the pending phase, then vote: the proposal qualifies
        vm.roll(block.number + 2);
        vm.prank(whale);
        harness.castVote(proposalId, IGovernanceVoting.VoteType.For);

        // qualifying sets the closing block to the current block
        wrapper = harness.getProposalById(proposalId);
        assertEq(wrapper.proposal.endBlockOrTime, block.number);
        assertEq(uint256(harness.getProposalState(proposalId)), uint256(IGovernanceState.ProposalState.Qualified));

        vm.roll(block.number + 1);
        harness.execute(proposalId);
        assertEq(uint256(harness.getProposalState(proposalId)), uint256(IGovernanceState.ProposalState.Executed));
    }

    /// @notice Qualifying and executing in a single transaction reverts in Blocknumber mode.
    function test_Blocknumber_SameTxQualifyAndExecute_Reverts() public {
        harness.setTimeType(TimeType.Blocknumber);
        uint256 proposalId = _createProposal();
        vm.roll(block.number + 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                MixinVoting.GovVotingClosed.selector,
                proposalId,
                IGovernanceState.ProposalState.Qualified
            )
        );
        bundler.qualifyAndExecute(address(harness), proposalId);
    }

    /// @notice A proposal qualified in Timestamp mode closes voting at the qualifying
    ///     timestamp and can be executed from the next timestamp on.
    function test_Timestamp_QualifiedProposal_ExecutesNextTimestamp() public {
        harness.setTimeType(TimeType.Timestamp);
        uint256 proposalId = _createProposal();

        // voting starts at block.timestamp + 1
        IGovernanceState.ProposalWrapper memory wrapper = harness.getProposalById(proposalId);
        assertEq(wrapper.proposal.startBlockOrTime, block.timestamp + 1);

        // pass the pending phase, then vote: the proposal qualifies
        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        harness.castVote(proposalId, IGovernanceVoting.VoteType.For);

        // qualifying sets the closing timestamp to the current timestamp
        wrapper = harness.getProposalById(proposalId);
        assertEq(wrapper.proposal.endBlockOrTime, block.timestamp);
        assertEq(uint256(harness.getProposalState(proposalId)), uint256(IGovernanceState.ProposalState.Qualified));

        vm.warp(block.timestamp + 1);
        harness.execute(proposalId);
        assertEq(uint256(harness.getProposalState(proposalId)), uint256(IGovernanceState.ProposalState.Executed));
    }

    /// @notice Qualifying and executing in a single transaction reverts in Timestamp mode.
    function test_Timestamp_SameTxQualifyAndExecute_Reverts() public {
        harness.setTimeType(TimeType.Timestamp);
        uint256 proposalId = _createProposal();
        vm.warp(block.timestamp + 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                MixinVoting.GovVotingClosed.selector,
                proposalId,
                IGovernanceState.ProposalState.Qualified
            )
        );
        bundler.qualifyAndExecute(address(harness), proposalId);
    }

    /// @notice A proposal that updates only the quorum threshold executes successfully.
    function test_UpdateThresholds_OnlyQuorumChanged_Executes() public {
        harness.setTimeType(TimeType.Timestamp);
        bytes memory data = abi.encodeWithSelector(
            IGovernanceUpgrade.updateThresholds.selector,
            PROPOSAL_THRESHOLD,
            LOWERED_QUORUM
        );
        uint256 proposalId = _createProposalWithData(data);

        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        harness.castVote(proposalId, IGovernanceVoting.VoteType.For);
        vm.warp(block.timestamp + 1);
        assertEq(uint256(harness.getProposalState(proposalId)), uint256(IGovernanceState.ProposalState.Succeeded));

        vm.expectEmit(address(harness));
        emit IGovernanceEvents.ThresholdsUpdated(PROPOSAL_THRESHOLD, LOWERED_QUORUM);
        harness.execute(proposalId);

        IGovernanceState.GovernanceParameters memory params = harness.governanceParameters().params;
        assertEq(params.quorumThreshold, LOWERED_QUORUM);
        assertEq(params.proposalThreshold, PROPOSAL_THRESHOLD);
    }

    /// @dev Creates a no-op proposal and returns its id.
    function _createProposal() private returns (uint256 proposalId) {
        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](1);
        actions[0] = IGovernanceVoting.ProposedAction({target: address(target), data: "", value: 0});
        vm.prank(whale);
        return harness.propose(actions, "time type proposal");
    }

    /// @dev Creates a proposal whose single action calls the harness with the given calldata.
    function _createProposalWithData(bytes memory data) private returns (uint256 proposalId) {
        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](1);
        actions[0] = IGovernanceVoting.ProposedAction({target: address(harness), data: data, value: 0});
        vm.prank(whale);
        return harness.propose(actions, "time type proposal");
    }
}
