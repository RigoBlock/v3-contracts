// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {ICoreBridge} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";

import {IGovernanceState} from "../../contracts/governance/interfaces/governance/IGovernanceState.sol";
import {IGovernanceStrategy} from "../../contracts/governance/interfaces/IGovernanceStrategy.sol";
import {IGovernanceUpgrade} from "../../contracts/governance/interfaces/governance/IGovernanceUpgrade.sol";
import {IRigoblockGovernanceFactory} from "../../contracts/governance/interfaces/IRigoblockGovernanceFactory.sol";
import {IWormholeReceiverStrategy} from "../../contracts/governance/strategies/interfaces/IWormholeReceiverStrategy.sol";
import {ProposalStatus, ProposedAction} from "../../contracts/governance/types/GovernanceTypes.sol";
import {TimeType} from "../../contracts/governance/types/TimeType.sol";
import {WormholeReceiverStrategy} from "../../contracts/governance/strategies/WormholeReceiverStrategy.sol";

/// @title Receiver-chain strategy: staking-free governance with a recovery escape hatch.
/// @notice Local governance is fail-closed until a recovery request crosses its challenge
///     window; the full recovery flow is covered in Governance.Recovery.t.sol.
contract WormholeReceiverStrategyTest is Test {
    address internal constant TARGET = address(0x3333);
    address internal constant GOVERNANCE_PROXY = address(0x5555);
    uint256 internal constant RECOVERY_WINDOW = 60 days;

    address internal wormhole;
    WormholeReceiverStrategy internal strategy;
    address internal recovery = makeAddr("recovery");

    function setUp() public {
        wormhole = makeAddr("wormhole");
        // enough code for the constructor's code.length check and chainId() probe
        vm.etch(wormhole, hex"00");
        vm.mockCall(wormhole, abi.encodeCall(ICoreBridge.chainId, ()), abi.encode(uint16(47)));
        // enough code for the constructor's governanceProxy code.length check
        vm.etch(GOVERNANCE_PROXY, hex"00");
        strategy = _receiverStrategy();
    }

    function _receiverStrategy() private returns (WormholeReceiverStrategy) {
        return new WormholeReceiverStrategy(wormhole, GOVERNANCE_PROXY, recovery);
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
        new WormholeReceiverStrategy(wormhole, GOVERNANCE_PROXY, address(0));
    }

    /// @dev The governance proxy authenticates recovery vetoes; a zero proxy would make the
    ///     veto unreachable.
    function test_Constructor_ZeroGovernanceProxy_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IWormholeReceiverStrategy.GovRecoveryInvalidProxy.selector, address(0)));
        new WormholeReceiverStrategy(wormhole, address(0), recovery);
    }

    /// @dev A zero wormhole address would make receiveMessage unusable.
    function test_Constructor_ZeroWormhole_Reverts() public {
        vm.expectRevert(IWormholeReceiverStrategy.GovRecoveryAddressZero.selector);
        new WormholeReceiverStrategy(address(0), GOVERNANCE_PROXY, recovery);
    }

    /// @dev An EOA wormhole would make the constructor probe return empty returndata.
    function test_Constructor_EoaWormhole_Reverts() public {
        vm.expectRevert(IWormholeReceiverStrategy.GovRecoveryAddressZero.selector);
        new WormholeReceiverStrategy(makeAddr("eoa"), GOVERNANCE_PROXY, recovery);
    }

    /// @dev An EOA governance proxy could never deliver a recovery veto.
    function test_Constructor_EoaGovernanceProxy_Reverts() public {
        address proxyEoa = makeAddr("proxyEoa");
        vm.expectRevert(abi.encodeWithSelector(IWormholeReceiverStrategy.GovRecoveryInvalidProxy.selector, proxyEoa));
        new WormholeReceiverStrategy(wormhole, proxyEoa, recovery);
    }

    function _params(
        uint256 proposalThreshold,
        uint256 quorumThreshold
    ) private pure returns (IRigoblockGovernanceFactory.Parameters memory) {
        return
            IRigoblockGovernanceFactory.Parameters({
                implementation: address(0),
                governanceStrategy: address(0),
                proposalThreshold: proposalThreshold,
                quorumThreshold: quorumThreshold,
                timeType: TimeType.Timestamp,
                name: "Rigoblock Governance"
            });
    }

    /// @dev Recovery voting power is hardcoded at type(uint96).max, so a threshold above the
    ///     cap bricks the recovery path and a zero threshold opens spam proposals.
    function test_ValidateParams_ThresholdsWithinUint96Bounds_Pass() public {
        strategy.validateParams(_params(1, 1));
        strategy.validateParams(_params(type(uint96).max, type(uint96).max));
    }

    function test_ValidateParams_ZeroProposalThreshold_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IGovernanceStrategy.GovStrategyInvalidProposalThreshold.selector, 0));
        strategy.validateParams(_params(0, 1));
    }

    function test_ValidateParams_ZeroQuorumThreshold_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IGovernanceStrategy.GovStrategyInvalidQuorumThreshold.selector, 0));
        strategy.validateParams(_params(1, 0));
    }

    function test_ValidateParams_ProposalThresholdAboveUint96_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceStrategy.GovStrategyInvalidProposalThreshold.selector,
                uint256(type(uint96).max) + 1
            )
        );
        strategy.validateParams(_params(uint256(type(uint96).max) + 1, 1));
    }

    function test_ValidateParams_QuorumThresholdAboveUint96_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceStrategy.GovStrategyInvalidQuorumThreshold.selector,
                uint256(type(uint96).max) + 1
            )
        );
        strategy.validateParams(_params(1, uint256(type(uint96).max) + 1));
    }

    /// @dev A contract without chainId() fails the constructor probe.
    function test_Constructor_NonWormholeContract_Reverts() public {
        address nonWormhole = address(new NonWormholeContract());
        vm.expectRevert(IWormholeReceiverStrategy.GovRecoveryAddressZero.selector);
        new WormholeReceiverStrategy(nonWormhole, GOVERNANCE_PROXY, recovery);
    }

    function test_BeforePropose_WithoutActiveRecovery_Reverts() public {
        vm.expectRevert(IWormholeReceiverStrategy.GovLocalGovernanceDisabled.selector);
        strategy.beforePropose(_actions(TARGET));
    }

    /// @dev Without an active recovery the local-governance gate reverts first, before the
    ///     wormhole-target check.
    function test_BeforePropose_WormholeTarget_WithoutActiveRecovery_RevertsDisabled() public {
        vm.expectRevert(IWormholeReceiverStrategy.GovLocalGovernanceDisabled.selector);
        strategy.beforePropose(_actions(wormhole));
    }

    /// @dev A recovery batch can never carry a wormhole action: it would revert on the fee at
    ///     execution time, and the succeeded proposal could not be cancelled.
    function test_BeforePropose_ActiveRecovery_WormholeTarget_Reverts() public {
        _activateRecovery();
        vm.expectRevert(IWormholeReceiverStrategy.GovCrosschainNotSender.selector);
        strategy.beforePropose(_actions(wormhole));
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

    /// @dev The voting window is empty: start == end == block.timestamp, so a non-recovery
    ///     proposal is never votable.
    function test_BeforePropose_ActiveRecovery_ReturnsEmptyWindow() public {
        _activateRecovery();
        (, uint256 startBlockOrTime, uint256 endBlockOrTime) = strategy.beforePropose(_actions(TARGET));
        assertEq(startBlockOrTime, block.timestamp);
        assertEq(endBlockOrTime, block.timestamp);
    }

    /// @dev No staking on receiver chains: the first-vote snapshot total is zero.
    function test_BeforeVote_ReturnsZero() public {
        assertEq(strategy.beforeVote(), 0);
    }

    /// @dev Executed is terminal: a recovery proposal that has been executed keeps reading
    ///     Executed after the recovery is vetoed and cleared (audit-#5 regression).
    function test_GetProposalState_ExecutedStaysExecuted_AfterRecoveryCleared() public {
        IGovernanceState.Proposal memory proposal = IGovernanceState.Proposal({
            actionsLength: 1,
            startBlockOrTime: 1,
            endBlockOrTime: 2,
            votesFor: 0,
            votesAgainst: 0,
            votesAbstain: 0,
            executed: true
        });

        _activateRecovery();
        assertEq(
            uint256(strategy.getProposalState(proposal, recovery, 0, 0, TimeType.Timestamp)),
            uint256(ProposalStatus.Executed)
        );

        vm.prank(GOVERNANCE_PROXY);
        strategy.rejectRecover();

        assertEq(
            uint256(strategy.getProposalState(proposal, recovery, 0, 0, TimeType.Timestamp)),
            uint256(ProposalStatus.Executed)
        );
    }

    /// @dev The governance name is validated; a wrong name fails the initializer-level assert
    ///     regardless of threshold values.
    function test_ValidateParams_WrongName_Reverts() public {
        IRigoblockGovernanceFactory.Parameters memory params = _params(1, 1);
        params.name = "Wrong Name";
        vm.expectRevert();
        strategy.validateParams(params);
    }

    /// @dev `beforePropose` performs no threshold validation, so an updateThresholds proposal
    ///     passes propose-time validation untouched; the bounds are enforced at execution
    ///     time via validateParams.
    function test_BeforePropose_ActiveRecovery_ThresholdUpdate_Passes() public {
        _activateRecovery();
        bytes memory data = abi.encodeWithSelector(IGovernanceUpgrade.updateThresholds.selector, 0, type(uint256).max);
        ProposedAction[] memory actions = new ProposedAction[](1);
        actions[0] = ProposedAction({target: TARGET, data: data, value: 0});
        (ProposedAction[] memory result, , ) = strategy.beforePropose(actions);
        assertEq(result[0].target, TARGET);
    }

    function test_WormholeConfig_Readable() public {
        assertEq(strategy.wormhole(), wormhole);
        // the local Wormhole chain id is not strategy state: it is read from the core contract
        assertEq(ICoreBridge(wormhole).chainId(), 47);
    }
}

/// @dev A plain contract without a chainId() function, for the constructor probe test.
contract NonWormholeContract {}
