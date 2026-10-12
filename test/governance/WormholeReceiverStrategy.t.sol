// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {IGovernanceState} from "../../contracts/governance/interfaces/governance/IGovernanceState.sol";
import {IGovernanceStrategy} from "../../contracts/governance/interfaces/IGovernanceStrategy.sol";
import {IRigoblockGovernanceFactory} from "../../contracts/governance/interfaces/IRigoblockGovernanceFactory.sol";
import {IWormholeReceiverStrategy} from "../../contracts/governance/strategies/interfaces/IWormholeReceiverStrategy.sol";
import {ProposalStatus, ProposedAction} from "../../contracts/governance/types/GovernanceTypes.sol";
import {TimeType} from "../../contracts/governance/types/TimeType.sol";
import {WormholeReceiverStrategy} from "../../contracts/governance/strategies/WormholeReceiverStrategy.sol";

/// @title Receiver-chain strategy: staking-free governance with a recovery escape hatch.
/// @notice Local governance is fail-closed until a recovery request crosses its challenge
///     window; the full recovery flow is covered in Governance.Recovery.t.sol.
contract WormholeReceiverStrategyTest is Test {
    address internal constant WORMHOLE = address(0x4444);
    address internal constant TARGET = address(0x3333);
    address internal constant GOVERNANCE_PROXY = address(0x5555);
    uint16 internal constant TARGET_CHAIN_ID = 47;
    uint256 internal constant RECOVERY_WINDOW = 60 days;

    WormholeReceiverStrategy internal strategy;
    address internal recovery = makeAddr("recovery");

    function setUp() public {
        strategy = _receiverStrategy();
    }

    function _receiverStrategy() private returns (WormholeReceiverStrategy) {
        return new WormholeReceiverStrategy(WORMHOLE, TARGET_CHAIN_ID, GOVERNANCE_PROXY, recovery);
    }

    function _actions(address target) private pure returns (ProposedAction[] memory) {
        ProposedAction[] memory actions = new ProposedAction[](1);
        actions[0] = ProposedAction({target: target, data: "", value: 0});
        return actions;
    }

    function _activateRecovery() internal {
        vm.prank(recovery);
        strategy.requestRecover();
        // window boundary is inclusive: exactly requestedAt + RECOVERY_WINDOW activates
        vm.warp(block.timestamp + RECOVERY_WINDOW);
    }

    /// @dev A receiver-chain strategy without a recovery address is a permanently dead
    ///     hatch; the constructor must not allow it even in a hand deployment.
    function test_Constructor_ZeroRecoveryAddress_Reverts() public {
        vm.expectRevert(IWormholeReceiverStrategy.GovRecoveryAddressZero.selector);
        new WormholeReceiverStrategy(WORMHOLE, TARGET_CHAIN_ID, GOVERNANCE_PROXY, address(0));
    }

    /// @dev The governance proxy authenticates recovery vetoes; a zero proxy would make the
    ///     veto unreachable.
    function test_Constructor_ZeroGovernanceProxy_Reverts() public {
        vm.expectRevert(IWormholeReceiverStrategy.GovRecoveryAddressZero.selector);
        new WormholeReceiverStrategy(WORMHOLE, TARGET_CHAIN_ID, address(0), recovery);
    }

    function test_BeforePropose_WithoutActiveRecovery_Reverts() public {
        vm.expectRevert(IWormholeReceiverStrategy.GovLocalGovernanceDisabled.selector);
        strategy.beforePropose(_actions(TARGET));
    }

    /// @dev With an active recovery even a Wormhole-target action passes propose-time
    ///     validation: sending is blocked on the receiver by the implementation's trusted
    ///     emitter pinning, not by the strategy.
    function test_BeforePropose_ActiveRecovery_WormholeTarget_Passes() public {
        _activateRecovery();
        ProposedAction[] memory result = strategy.beforePropose(_actions(WORMHOLE));
        assertEq(result[0].target, WORMHOLE);
    }

    function test_BeforeExecute_PassesThrough() public {
        ProposedAction[] memory result = strategy.beforeExecute(_actions(TARGET));
        assertEq(result[0].target, TARGET);
        assertEq(result[0].value, 0);
    }

    function test_GetVotingPower_ReturnsZeroWithoutRecovery() public {
        assertEq(strategy.getVotingPower(makeAddr("anyone")), 0);
        assertEq(strategy.getVotingPower(recovery), 0);
    }

    function test_GetVotingPower_ActiveRecovery_RecoveryAddressOnly() public {
        _activateRecovery();
        assertEq(strategy.getVotingPower(recovery), type(uint96).max);
        assertEq(strategy.getVotingPower(makeAddr("anyone")), 0);
    }

    /// @dev The receiver has no voting: only a proposal created by the recovery address
    ///     during an active recovery reads Succeeded; everything else is Defeated. Execution
    ///     status is reported by the governance, not the strategy.
    function test_GetProposalState_ProposerBased() public {
        IGovernanceState.Proposal memory proposal = IGovernanceState.Proposal({
            actionsLength: 1,
            startBlockOrTime: 1,
            endBlockOrTime: 2,
            votesFor: 0,
            votesAgainst: 0,
            votesAbstain: 0,
            executed: false
        });

        // no recovery: everyone is Defeated
        assertEq(
            uint256(strategy.getProposalState(proposal, recovery, 0, 0, TimeType.Timestamp)),
            uint256(ProposalStatus.Defeated)
        );

        _activateRecovery();

        // recovery active: only the recovery address's proposal succeeds, and immediately
        assertEq(
            uint256(strategy.getProposalState(proposal, recovery, 0, 0, TimeType.Timestamp)),
            uint256(ProposalStatus.Succeeded)
        );
        assertEq(
            uint256(strategy.getProposalState(proposal, makeAddr("other"), 0, 0, TimeType.Timestamp)),
            uint256(ProposalStatus.Defeated)
        );

        // a recovery-vetoed proposal flips back to Defeated
        vm.prank(GOVERNANCE_PROXY);
        strategy.rejectRecover();
        assertEq(
            uint256(strategy.getProposalState(proposal, recovery, 0, 0, TimeType.Timestamp)),
            uint256(ProposalStatus.Defeated)
        );
    }

    function test_VotingPeriod_ReturnsZero() public {
        assertEq(strategy.votingPeriod(), 0);
    }

    function test_VotingTimestamps_ReturnsCurrentTimestamp() public {
        (uint256 startBlockOrTime, uint256 endBlockOrTime) = strategy.votingTimestamps(TimeType.Timestamp);
        assertEq(startBlockOrTime, block.timestamp);
        assertEq(endBlockOrTime, block.timestamp);
    }

    function test_TotalVotingPower_ReturnsZero() public {
        assertEq(strategy.totalVotingPower(), 0);
    }

    /// @dev The receiver governance has no thresholds: any value is accepted, including zero
    ///     and values far above the recovery address's fixed power.
    function test_AssertValidInitParams_OnlyValidatesName() public {
        IRigoblockGovernanceFactory.Parameters memory params = IRigoblockGovernanceFactory.Parameters({
            implementation: address(0),
            governanceStrategy: address(strategy),
            proposalThreshold: 0,
            quorumThreshold: 0,
            timeType: TimeType.Blocknumber,
            name: "Rigoblock Governance"
        });
        strategy.assertValidInitParams(params);

        params.name = "Wrong Name";
        vm.expectRevert();
        strategy.assertValidInitParams(params);
    }

    /// @dev Receiver governance has no voting thresholds, so the threshold validators accept
    ///     any value.
    function test_ThresholdValidators_AcceptAnything() public {
        strategy.assertValidProposalThreshold(0);
        strategy.assertValidProposalThreshold(type(uint256).max);
        strategy.assertValidQuorumThreshold(0);
        strategy.assertValidQuorumThreshold(type(uint256).max);
    }

    function test_WormholeConfig_Readable() public {
        assertEq(strategy.wormhole(), WORMHOLE);
        assertEq(strategy.wormholeChainId(), TARGET_CHAIN_ID);
    }
}
