// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {IGovernanceState} from "../../contracts/governance/interfaces/governance/IGovernanceState.sol";
import {IGovernanceStrategy} from "../../contracts/governance/interfaces/IGovernanceStrategy.sol";
import {IGovernanceVoting} from "../../contracts/governance/interfaces/governance/IGovernanceVoting.sol";
import {IRigoblockGovernanceFactory} from "../../contracts/governance/interfaces/IRigoblockGovernanceFactory.sol";
import {IWormholeReceiverStrategy} from "../../contracts/governance/strategies/interfaces/IWormholeReceiverStrategy.sol";
import {ProposalStatus} from "../../contracts/governance/types/GovernanceTypes.sol";
import {TimeType} from "../../contracts/governance/types/TimeType.sol";
import {WormholeReceiverStrategy} from "../../contracts/governance/strategies/WormholeReceiverStrategy.sol";

/// @title Receiver-chain strategy: staking-free governance with a recovery escape hatch.
/// @notice Local governance is fail-closed until a recovery request crosses its challenge
///     window; the full recovery flow is covered in Governance.Recovery.t.sol.
contract WormholeReceiverStrategyTest is Test {
    address internal constant WORMHOLE = address(0x4444);
    address internal constant TARGET = address(0x3333);
    uint16 internal constant TARGET_CHAIN_ID = 47;

    WormholeReceiverStrategy internal strategy;

    function setUp() public {
        strategy = _receiverStrategy();
    }

    function _receiverStrategy() private returns (WormholeReceiverStrategy) {
        return new WormholeReceiverStrategy(WORMHOLE, TARGET_CHAIN_ID, makeAddr("recovery"));
    }

    function _actions(address target) private pure returns (IGovernanceVoting.ProposedAction[] memory) {
        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](1);
        actions[0] = IGovernanceVoting.ProposedAction({target: target, data: "", value: 0});
        return actions;
    }

    /// @dev A receiver-chain strategy without a recovery address is a permanently dead
    ///     hatch; the constructor must not allow it even in a hand deployment.
    function test_Constructor_ZeroRecoveryAddress_Reverts() public {
        vm.expectRevert(IWormholeReceiverStrategy.GovRecoveryAddressZero.selector);
        new WormholeReceiverStrategy(WORMHOLE, TARGET_CHAIN_ID, address(0));
    }

    function test_BeforePropose_WithoutActiveRecovery_Reverts() public {
        vm.expectRevert(IWormholeReceiverStrategy.GovLocalGovernanceDisabled.selector);
        strategy.beforePropose(_actions(TARGET));
    }

    function test_BeforeExecute_WithoutActiveRecovery_Reverts() public {
        vm.expectRevert(IWormholeReceiverStrategy.GovLocalGovernanceDisabled.selector);
        strategy.beforeExecute(_actions(TARGET));
    }

    function test_VotingTimestamps_WithoutActiveRecovery_Reverts() public {
        vm.expectRevert(IWormholeReceiverStrategy.GovLocalGovernanceDisabled.selector);
        strategy.votingTimestamps(TimeType.Timestamp);
    }

    function test_BeforeVote_ReturnsZero() public {
        assertEq(strategy.beforeVote(0), 0);
        assertEq(strategy.beforeVote(123), 0);
    }

    function test_GetVotingPower_ReturnsZeroWithoutRecovery() public {
        assertEq(strategy.getVotingPower(makeAddr("anyone")), 0);
        assertEq(strategy.getVotingPower(makeAddr("recovery")), 0);
    }

    function test_GetProposalState_ReturnsDefeatedWithoutStaking() public {
        // values are irrelevant: without an active recovery the proposal is Defeated
        IGovernanceState.Proposal memory proposal = IGovernanceState.Proposal({
            actionsLength: 1,
            startBlockOrTime: 1,
            endBlockOrTime: 2,
            votesFor: 100,
            votesAgainst: 0,
            votesAbstain: 0,
            executed: false
        });
        assertEq(
            uint256(strategy.getProposalState(proposal, 1, 0, TimeType.Timestamp)),
            uint256(ProposalStatus.Defeated)
        );
    }

    function test_VotingPeriod_ReturnsDefaultWithoutStaking() public {
        assertEq(strategy.votingPeriod(), 7 days);
    }

    function test_TotalVotingPower_ReturnsZero() public {
        assertEq(strategy.totalVotingPower(), 0);
    }

    function test_AssertValidInitParams_BoundedThresholdValidation() public {
        IRigoblockGovernanceFactory.Parameters memory params = IRigoblockGovernanceFactory.Parameters({
            implementation: address(0),
            governanceStrategy: address(strategy),
            proposalThreshold: 1,
            quorumThreshold: 1,
            timeType: TimeType.Timestamp,
            name: "Rigoblock Governance"
        });
        // bounds are staking-free on receiver chains: in-range thresholds pass, zero and
        // above-uint96 thresholds revert
        strategy.assertValidInitParams(params);

        params.proposalThreshold = 0;
        vm.expectRevert(
            abi.encodeWithSelector(IWormholeReceiverStrategy.GovStrategyInvalidReceiverThreshold.selector, 0)
        );
        strategy.assertValidInitParams(params);

        params.proposalThreshold = 1;
        params.quorumThreshold = 0;
        vm.expectRevert(
            abi.encodeWithSelector(IWormholeReceiverStrategy.GovStrategyInvalidReceiverThreshold.selector, 0)
        );
        strategy.assertValidInitParams(params);

        params.quorumThreshold = uint256(type(uint96).max) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IWormholeReceiverStrategy.GovStrategyInvalidReceiverThreshold.selector,
                uint256(type(uint96).max) + 1
            )
        );
        strategy.assertValidInitParams(params);
    }

    function test_AssertValidInitParams_Blocknumber_Reverts() public {
        IRigoblockGovernanceFactory.Parameters memory params = IRigoblockGovernanceFactory.Parameters({
            implementation: address(0),
            governanceStrategy: address(strategy),
            proposalThreshold: 0,
            quorumThreshold: 0,
            timeType: TimeType.Blocknumber,
            name: "Rigoblock Governance"
        });
        vm.expectRevert(
            abi.encodeWithSelector(IGovernanceStrategy.GovStrategyInvalidTimeType.selector, TimeType.Blocknumber)
        );
        strategy.assertValidInitParams(params);
    }

    function test_VotingTimestamps_Blocknumber_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IGovernanceStrategy.GovStrategyInvalidTimeType.selector, TimeType.Blocknumber)
        );
        strategy.votingTimestamps(TimeType.Blocknumber);
    }

    /// @dev Thresholds are staking-free but bounded: zero would let anyone create inert
    ///     proposals, and a threshold above the recovery address's uint96 power would brick
    ///     recovery. Boundary values are accepted.
    function test_ThresholdValidators_BoundedWithoutStaking() public {
        strategy.assertValidProposalThreshold(1);
        strategy.assertValidProposalThreshold(type(uint96).max);
        strategy.assertValidQuorumThreshold(1);
        strategy.assertValidQuorumThreshold(type(uint96).max);

        vm.expectRevert(
            abi.encodeWithSelector(IWormholeReceiverStrategy.GovStrategyInvalidReceiverThreshold.selector, uint256(0))
        );
        strategy.assertValidProposalThreshold(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWormholeReceiverStrategy.GovStrategyInvalidReceiverThreshold.selector,
                uint256(type(uint96).max) + 1
            )
        );
        strategy.assertValidQuorumThreshold(uint256(type(uint96).max) + 1);
    }

    function test_WormholeConfig_Readable() public {
        assertEq(strategy.wormhole(), WORMHOLE);
        assertEq(strategy.wormholeChainId(), TARGET_CHAIN_ID);
    }
}
