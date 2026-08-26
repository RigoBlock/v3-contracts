// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {RigoblockGovernance} from "../../contracts/governance/RigoblockGovernance.sol";
import {IGovernanceState} from "../../contracts/governance/interfaces/governance/IGovernanceState.sol";
import {IGovernanceVoting} from "../../contracts/governance/interfaces/governance/IGovernanceVoting.sol";
import {IGovernanceUpgrade} from "../../contracts/governance/interfaces/governance/IGovernanceUpgrade.sol";
import {IGovernanceStrategy} from "../../contracts/governance/interfaces/IGovernanceStrategy.sol";

/// @title GovernanceMigrationForkTest
/// @notice Mainnet-fork migration test for the governance implementation upgrade that
///     introduces the `proposalQuorumById` snapshot mapping.
/// @dev The test performs the upgrade through real governance proposals on the live proxy.
///     Only the voter's voting power is mocked (the staking system is otherwise left untouched);
///     proposals are created, voted on and executed through the real governance methods.
contract GovernanceMigrationForkTest is Test {
    address internal constant PROXY = Constants.GOV_PROXY;

    RigoblockGovernance internal newImpl;

    address internal voter = makeAddr("voter");
    address internal strategy;

    /// @notice Enough GRG to exceed any mainnet quorum threshold and proposal threshold.
    uint256 internal constant VOTER_GRG = 2_000_000e18;

    function setUp() public {
        vm.createSelectFork("mainnet", Constants.MAINNET_BLOCK);
        newImpl = new RigoblockGovernance();
        strategy = IGovernanceState(PROXY).governanceParameters().params.strategy;

        // Give the test voter enough voting power to create and pass proposals. Strategy
        // action validation is mocked so the test is not coupled to the live strategy's rules.
        vm.mockCall(
            strategy,
            abi.encodeWithSelector(IGovernanceStrategy.getVotingPower.selector, voter),
            abi.encode(VOTER_GRG)
        );
        vm.mockCall(strategy, abi.encodeWithSelector(IGovernanceStrategy.validateAction.selector), abi.encode());
    }

    /// @notice Verifies that the upgrade proposal executes and that historical proposals
    ///     are then treated as legacy proposals that can never become executable again.
    function testFork_UpgradeProposal_ExecutesAndLegacyProposalsBecomeUnexecutable() public {
        _executeUpgradeProposal();

        uint256 count = IGovernanceState(PROXY).proposalCount();
        assertGt(count, 0, "no legacy proposals on fork");

        // Move past all voting periods so post-voting state logic applies.
        vm.warp(block.timestamp + 365 days);

        for (uint256 i = 1; i <= count; i++) {
            IGovernanceState.ProposalWrapper memory wrapper = IGovernanceState(PROXY).getProposalById(i);
            if (wrapper.proposal.executed) continue;

            IGovernanceState.ProposalState state = IGovernanceState(PROXY).getProposalState(i);
            assertFalse(state == IGovernanceState.ProposalState.Succeeded, "legacy proposal became Succeeded");
            assertFalse(state == IGovernanceState.ProposalState.Queued, "legacy proposal became Queued");
            assertFalse(state == IGovernanceState.ProposalState.Expired, "legacy proposal became Expired");
        }
    }

    /// @notice Verifies that a proposal created after the upgrade snapshots the current
    ///     global quorum and reaches Succeeded using the real mainnet strategy.
    function testFork_NewProposal_AfterUpgrade_SnapshotsQuorum() public {
        _executeUpgradeProposal();

        IGovernanceState.EnhancedParams memory params = IGovernanceState(PROXY).governanceParameters();

        uint256 proposalId = _createVoteAndExecute(_noOpAction());

        assertEq(
            uint256(IGovernanceState(PROXY).getProposalState(proposalId)),
            uint256(IGovernanceState.ProposalState.Executed),
            "post-upgrade proposal should be Executed"
        );
    }

    /// @notice Verifies that changing the global quorum after the upgrade does not resurrect
    ///     any legacy proposal, while a proposal created after the change snapshots the new
    ///     quorum and can reach Succeeded.
    function testFork_ChangedQuorum_DoesNotResurrectLegacy() public {
        _executeUpgradeProposal();

        IGovernanceState.EnhancedParams memory params = IGovernanceState(PROXY).governanceParameters();

        // On mainnet the current quorum may be at the strategy floor, so first raise it to
        // create room for a later reduction. Thresholds must both change and stay within bounds.
        uint256 raisedProposalThreshold = params.params.proposalThreshold + 50_000e18;
        uint256 raisedQuorumThreshold = params.params.quorumThreshold + 200_000e18;
        _executeThresholdsProposal(raisedProposalThreshold, raisedQuorumThreshold);

        // Create a proposal while the quorum is raised, but do not vote on it.
        // It will be defeated at the raised quorum.
        uint256 defeatedProposalId = _createProposal(_noOpAction(), "defeated at raised quorum");
        _warpPastVotingPeriod(defeatedProposalId);
        assertEq(
            uint256(IGovernanceState(PROXY).getProposalState(defeatedProposalId)),
            uint256(IGovernanceState.ProposalState.Defeated),
            "proposal should be defeated at raised quorum"
        );

        // Lower the quorum. The defeated proposal must still use its snapshotted (raised) quorum.
        uint256 loweredProposalThreshold = raisedProposalThreshold - 25_000e18;
        uint256 loweredQuorumThreshold = raisedQuorumThreshold - 100_000e18;
        _executeThresholdsProposal(loweredProposalThreshold, loweredQuorumThreshold);

        assertEq(
            uint256(IGovernanceState(PROXY).getProposalState(defeatedProposalId)),
            uint256(IGovernanceState.ProposalState.Defeated),
            "lowering quorum resurrected legacy proposal"
        );

        // A new proposal created after the reduction snapshots the lowered quorum and succeeds.
        uint256 newProposalId = _createVoteAndExecute(_noOpAction());
        assertEq(
            uint256(IGovernanceState(PROXY).getProposalState(newProposalId)),
            uint256(IGovernanceState.ProposalState.Executed),
            "post-reduction proposal should be Executed"
        );
    }

    /// @dev Creates, votes on and executes a proposal to upgrade the governance implementation.
    /// @notice The upgrade proposal itself is created before the upgrade, so it has no quorum
    ///     snapshot. After the upgrade it is treated as a legacy proposal (max quorum) and
    ///     therefore reports Defeated state, which is expected: it has already been executed.
    function _executeUpgradeProposal() internal {
        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](1);
        actions[0] = IGovernanceVoting.ProposedAction({
            target: PROXY,
            data: abi.encodeWithSelector(IGovernanceUpgrade.upgradeImplementation.selector, address(newImpl)),
            value: 0
        });

        _createVoteAndExecute(actions);

        // Verify the proxy now delegates to the new implementation.
        assertEq(
            address(uint160(uint256(vm.load(PROXY, _implementationSlot())))),
            address(newImpl),
            "implementation was not upgraded"
        );
    }

    /// @dev Returns the EIP-1967 implementation slot used by the governance proxy.
    function _implementationSlot() internal pure returns (bytes32) {
        return 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    }

    /// @dev Creates, votes on and executes a proposal to update the governance thresholds.
    function _executeThresholdsProposal(uint256 proposalThreshold, uint256 quorumThreshold) internal {
        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](1);
        actions[0] = IGovernanceVoting.ProposedAction({
            target: PROXY,
            data: abi.encodeWithSelector(
                IGovernanceUpgrade.updateThresholds.selector,
                proposalThreshold,
                quorumThreshold
            ),
            value: 0
        });

        _createVoteAndExecute(actions);

        IGovernanceState.EnhancedParams memory params = IGovernanceState(PROXY).governanceParameters();
        assertEq(params.params.proposalThreshold, proposalThreshold);
        assertEq(params.params.quorumThreshold, quorumThreshold);
    }

    /// @dev Creates a proposal as the voter, casts the voter's full voting power for it and
    ///     executes it once the voting period ends.
    function _createVoteAndExecute(
        IGovernanceVoting.ProposedAction[] memory actions
    ) internal returns (uint256 proposalId) {
        proposalId = _createProposal(actions, "proposal");

        IGovernanceState.ProposalWrapper memory wrapper = IGovernanceState(PROXY).getProposalById(proposalId);
        vm.warp(wrapper.proposal.startBlockOrTime + 1);

        vm.prank(voter);
        IGovernanceVoting(PROXY).castVote(proposalId, IGovernanceVoting.VoteType.For);

        _warpPastVotingPeriod(proposalId);

        vm.prank(voter);
        IGovernanceVoting(PROXY).execute(proposalId);
    }

    /// @dev Creates a proposal as the voter.
    function _createProposal(
        IGovernanceVoting.ProposedAction[] memory actions,
        string memory description
    ) internal returns (uint256 proposalId) {
        vm.prank(voter);
        return IGovernanceVoting(PROXY).propose(actions, description);
    }

    /// @dev Warps past the voting period of a proposal.
    function _warpPastVotingPeriod(uint256 proposalId) internal {
        IGovernanceState.ProposalWrapper memory wrapper = IGovernanceState(PROXY).getProposalById(proposalId);
        vm.warp(wrapper.proposal.endBlockOrTime + 1);
    }

    /// @dev Returns a no-op action used for proposals whose execution result is irrelevant.
    function _noOpAction() internal pure returns (IGovernanceVoting.ProposedAction[] memory actions) {
        actions = new IGovernanceVoting.ProposedAction[](1);
        actions[0] = IGovernanceVoting.ProposedAction({target: address(0), data: "", value: 0});
    }
}
