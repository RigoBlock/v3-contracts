// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {RigoblockGovernanceStrategy} from "../../contracts/governance/strategies/RigoblockGovernanceStrategy.sol";
import {IGovernanceStrategy} from "../../contracts/governance/interfaces/IGovernanceStrategy.sol";
import {IWormholeReceiverStrategy} from "../../contracts/governance/strategies/interfaces/IWormholeReceiverStrategy.sol";
import {WormholeReceiverStrategy} from "../../contracts/governance/strategies/WormholeReceiverStrategy.sol";
import {MixinVoting} from "../../contracts/governance/mixins/MixinVoting.sol";
import {CrossChainPayload, ProposalStatus, ProposedAction, ProposalExtraData} from "../../contracts/governance/types/GovernanceTypes.sol";
import {IGovernanceUpgrade} from "../../contracts/governance/interfaces/governance/IGovernanceUpgrade.sol";
import {IGovernanceVoting} from "../../contracts/governance/interfaces/governance/IGovernanceVoting.sol";
import {IStructs} from "../../contracts/staking/interfaces/IStructs.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {TimeType} from "../../contracts/governance/types/TimeType.sol";

import {Test} from "forge-std/Test.sol";
import {IStorage} from "../../contracts/staking/interfaces/IStorage.sol";
import {ICoreBridge, CoreBridgeVM, GuardianSignature} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";
import {CHAIN_ID_ETHEREUM, CHAIN_ID_HYPER_EVM} from "wormhole-solidity-sdk/src/constants/Chains.sol";
import {Constants} from "../../contracts/test/Constants.sol";

import {Counter, CrosschainHarness} from "./Governance.Crosschain.t.sol";

/// @title Tests for the strategy-only governance recovery on receiver chains.
/// @notice The recovery flow must work even when staking is dead or emptied: every test below
///     either reverts every staking call or mocks an emptied staking contract.
contract GovernanceRecoveryTest is Test {
    uint16 internal constant TARGET_CHAIN = CHAIN_ID_HYPER_EVM;
    address internal constant STAKING = address(0x1111);
    address internal wormhole;
    uint256 internal constant PROPOSAL_THRESHOLD = 100_000e18;
    uint256 internal constant QUORUM_THRESHOLD = 400_000e18;
    uint256 internal constant RECOVERY_WINDOW = 60 days;

    CrosschainHarness internal governance;
    WormholeReceiverStrategy internal strategy;
    Counter internal counter;
    address internal recovery = makeAddr("recovery");
    address internal whale = makeAddr("whale");

    function setUp() public {
        // the strategy authenticates the governance proxy by its chain-independent canonical
        // address, so the harness must live exactly there
        CrosschainHarness harness = new CrosschainHarness();
        vm.etch(Constants.GOV_PROXY, address(harness).code);
        governance = CrosschainHarness(payable(Constants.GOV_PROXY));
        governance.setName();
        wormhole = makeAddr("wormhole");
        // enough code for the constructor's code.length check; the local Wormhole chain id is
        // read from the core contract, which is not deployed in these tests
        vm.etch(wormhole, hex"00");
        vm.mockCall(wormhole, abi.encodeWithSelector(ICoreBridge.chainId.selector), abi.encode(TARGET_CHAIN));
        strategy = new WormholeReceiverStrategy(wormhole, Constants.GOV_PROXY, recovery);
        governance.setStrategy(address(strategy));
        governance.setParams(PROPOSAL_THRESHOLD, QUORUM_THRESHOLD);
        // the etch skips the constructor, which defaults the params to Timestamp
        governance.setTimeType(TimeType.Timestamp);
        counter = new Counter();
    }

    function _activateRecovery() internal {
        vm.prank(recovery);
        strategy.requestRecover();
        // window boundary is inclusive: exactly requestedAt + RECOVERY_WINDOW activates
        vm.warp(block.timestamp + RECOVERY_WINDOW);
    }

    /// @dev The recoverer creates a proposal, which the receiver strategy reports as
    ///     Succeeded immediately: no voting window, no vote needed.
    function _proposeRecovery() internal returns (uint256 proposalId) {
        vm.prank(recovery);
        proposalId = governance.propose(_incrementActions(), "recovery proposal");
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Succeeded));
    }

    /// @notice Reverts every staking selector the governance flow could touch, so the recovery
    ///     tests prove the flow is fully staking-free.
    function _brickStaking() internal {
        bytes memory reason = abi.encodeWithSignature("Error(string)", "staking bricked");
        vm.mockCallRevert(STAKING, abi.encodeWithSelector(IStaking.getOwnerStakeByStatus.selector), reason);
        vm.mockCallRevert(STAKING, abi.encodeWithSelector(IStaking.getGlobalStakeByStatus.selector), reason);
        vm.mockCallRevert(
            STAKING,
            abi.encodeWithSelector(IStaking.getCurrentEpochEarliestEndTimeInSeconds.selector),
            reason
        );
        vm.mockCallRevert(STAKING, abi.encodeWithSelector(IStorage.epochDurationInSeconds.selector), reason);
        vm.mockCallRevert(STAKING, abi.encodeWithSelector(IStaking.getGrgContract.selector), reason);
    }

    function test_RequestRejectRecover_Auth() public {
        vm.expectRevert(abi.encodeWithSelector(IWormholeReceiverStrategy.GovRecoveryUnauthorized.selector, whale));
        vm.prank(whale);
        strategy.requestRecover();

        vm.expectEmit();
        emit IWormholeReceiverStrategy.RecoverRequested(block.timestamp);
        vm.prank(recovery);
        strategy.requestRecover();

        vm.expectRevert(IWormholeReceiverStrategy.GovRecoveryAlreadyPending.selector);
        vm.prank(recovery);
        strategy.requestRecover();

        vm.expectRevert(abi.encodeWithSelector(IWormholeReceiverStrategy.GovRecoveryUnauthorized.selector, whale));
        vm.prank(whale);
        strategy.rejectRecover();

        // the rejection runs as a governance-proxy-delivered action, i.e. with msg.sender == proxy
        vm.expectEmit();
        emit IWormholeReceiverStrategy.RecoverRejected();
        vm.prank(address(governance));
        strategy.rejectRecover();

        vm.expectRevert(IWormholeReceiverStrategy.GovRecoveryNotPending.selector);
        vm.prank(address(governance));
        strategy.rejectRecover();
    }

    /// @notice A pending request that has not crossed the window changes nothing.
    function test_PendingRequest_ReceiverStillDisabled() public {
        vm.prank(recovery);
        strategy.requestRecover();
        vm.warp(block.timestamp + RECOVERY_WINDOW - 1);

        assertEq(strategy.getVotingPower(recovery), 0);
        // the receiver has no voting window, no snapshot total and no propose path outside a recovery
        assertEq(strategy.beforeVote(ProposalExtraData(0, 0)), 0);
        vm.expectRevert(IWormholeReceiverStrategy.GovLocalGovernanceDisabled.selector);
        strategy.beforePropose(_incrementActions());
    }

    /// @notice Re-requesting once the recovery is active would disarm it; it must revert.
    function test_ActiveRecovery_ReRequest_Reverts() public {
        _activateRecovery();

        vm.expectRevert(IWormholeReceiverStrategy.GovRecoveryAlreadyPending.selector);
        vm.prank(recovery);
        strategy.requestRecover();

        // still active and usable
        assertEq(strategy.getVotingPower(recovery), type(uint96).max);
    }

    /// @notice Recovery voting power is a fixed uint96 max: far above any real quorum, fitting
    ///     the vote receipt without truncation, and zero for everyone else.
    function test_Recovery_RecoveryPowerIsUint96Max() public {
        _activateRecovery();
        assertEq(strategy.getVotingPower(recovery), type(uint96).max);
        assertEq(strategy.getVotingPower(whale), 0);
    }

    /// @notice Thresholds at exactly type(uint96).max are reachable: the recovery power equals
    ///     the cap, so the full recovery flow still completes.
    function test_Recovery_MaxUint96Thresholds_RecoveryExecutes() public {
        governance.setParams(uint256(type(uint96).max), uint256(type(uint96).max));
        _activateRecovery();

        uint256 proposalId = _proposeRecovery();
        governance.execute(proposalId);
        assertEq(counter.value(), 1);
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Executed));
    }

    /// @notice A recovery proposal carrying thresholds above the uint96 cap passes propose
    ///     (no threshold checks at propose time) and reverts at execution, where
    ///     updateThresholds runs validateParams on the post-update parameters.
    function test_Recovery_UpdateThresholdsAboveUint96_RevertsAtExecute() public {
        _activateRecovery();

        vm.startPrank(recovery);
        ProposedAction[] memory actions = new ProposedAction[](1);
        actions[0] = ProposedAction({
            target: address(governance),
            data: abi.encodeCall(
                IGovernanceUpgrade.updateThresholds,
                (uint256(type(uint96).max) + 1, QUORUM_THRESHOLD)
            ),
            value: 0
        });
        uint256 proposalId = governance.propose(actions, "proposal threshold above the cap");
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceStrategy.GovStrategyInvalidProposalThreshold.selector,
                uint256(type(uint96).max) + 1
            )
        );
        governance.execute(proposalId);

        actions[0] = ProposedAction({
            target: address(governance),
            data: abi.encodeCall(
                IGovernanceUpgrade.updateThresholds,
                (PROPOSAL_THRESHOLD, uint256(type(uint96).max) + 1)
            ),
            value: 0
        });
        uint256 quorumProposalId = governance.propose(actions, "quorum threshold above the cap");
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceStrategy.GovStrategyInvalidQuorumThreshold.selector,
                uint256(type(uint96).max) + 1
            )
        );
        governance.execute(quorumProposalId);
        vm.stopPrank();
    }

    /// @notice Full recovery flow with a fully bricked staking contract: the recovery proposal
    ///     is Succeeded from creation (no staking read anywhere) and executes immediately.
    function test_Recovery_BrickedStaking_RecoveryExecutes() public {
        _brickStaking();
        _activateRecovery();

        uint256 proposalId = _proposeRecovery();
        governance.execute(proposalId);
        assertEq(counter.value(), 1);
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Executed));
    }

    /// @notice Staking alive but emptied (global delegated 0, the bridged-token-burn case):
    ///     the receiver strategy never reads staking, so the recovery proposal is Succeeded
    ///     from creation and the flow completes.
    function test_Recovery_EmptiedStaking_RecoveryExecutes() public {
        IStructs.StoredBalance memory zeroBalance;
        vm.mockCall(STAKING, abi.encodeWithSelector(IStaking.getGlobalStakeByStatus.selector), abi.encode(zeroBalance));

        _activateRecovery();

        uint256 proposalId = _proposeRecovery();
        governance.execute(proposalId);
        assertEq(counter.value(), 1);
    }

    /// @notice A mainnet veto landing after the recovery proposal is created flips it back to
    ///     Defeated and locks execution.
    function test_Recovery_VetoAfterProposal_LocksProposal() public {
        _activateRecovery();
        uint256 proposalId = _proposeRecovery();

        vm.prank(address(governance));
        strategy.rejectRecover();

        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Defeated));
        vm.expectRevert(
            abi.encodeWithSelector(MixinVoting.GovVotingClosed.selector, proposalId, ProposalStatus.Defeated)
        );
        governance.execute(proposalId);

        // local governance is disabled again
        vm.expectRevert(IWormholeReceiverStrategy.GovLocalGovernanceDisabled.selector);
        strategy.beforePropose(_incrementActions());
    }

    /// @notice A proposal executed during an active recovery keeps reading Executed after the
    ///     recovery ends: executed is terminal and the receiver gate must not rewrite it.
    function test_Recovery_ExecutedProposal_StaysExecuted_AfterVeto() public {
        _activateRecovery();
        uint256 proposalId = _proposeRecovery();

        governance.execute(proposalId);
        assertEq(counter.value(), 1);

        vm.prank(address(governance));
        strategy.rejectRecover();

        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Executed));
    }

    /// @notice A Wormhole-target action in a recovery batch reverts at propose time: it would
    ///     revert on the message fee at execution time, leaving the proposal stuck in
    ///     Succeeded with no cancellation path.
    function test_Recovery_WormholeAction_ProposeReverts() public {
        _activateRecovery();
        ProposedAction[] memory actions = new ProposedAction[](1);
        actions[0] = ProposedAction({target: wormhole, data: "", value: 0});
        vm.prank(recovery);
        vm.expectRevert(IWormholeReceiverStrategy.GovCrosschainNotSender.selector);
        governance.propose(actions, "wormhole-target proposal");
    }

    /// @notice A staking-backed governance can be turned into a receiver governance by a single
    ///     local proposal that swaps the strategy: the proxy and its storage are untouched, local
    ///     governance is fail-closed right after the switch, and cross-chain receiving keeps
    ///     working unchanged.
    function test_StakingToReceiver_Transition_UpgradesSmoothly() public {
        RigoblockGovernanceStrategy senderStrategy = new RigoblockGovernanceStrategy(STAKING, wormhole);
        governance.setStrategy(address(senderStrategy));

        // local voting power for the staking-backed phase
        IStructs.StoredBalance memory balance = IStructs.StoredBalance({
            currentEpoch: 1,
            currentEpochBalance: uint96(1_000_000e18),
            nextEpochBalance: uint96(1_000_000e18)
        });
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getOwnerStakeByStatus.selector, whale, IStructs.StakeStatus.DELEGATED),
            abi.encode(balance)
        );
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getGlobalStakeByStatus.selector, IStructs.StakeStatus.DELEGATED),
            abi.encode(balance)
        );
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getCurrentEpochEarliestEndTimeInSeconds.selector),
            abi.encode(block.timestamp + 1)
        );
        // the first vote's best-effort roll calls endEpoch: return proper ABI data, a bare
        // no-code call would revert in a way that bypasses the strategy's try/catch
        vm.mockCall(STAKING, abi.encodeWithSelector(IStaking.endEpoch.selector), abi.encode(uint256(0)));
        vm.mockCall(STAKING, abi.encodeWithSelector(IStorage.epochDurationInSeconds.selector), abi.encode(7 days));

        WormholeReceiverStrategy receiverStrategy = new WormholeReceiverStrategy(
            wormhole,
            Constants.GOV_PROXY,
            recovery
        );

        ProposedAction[] memory actions = new ProposedAction[](1);
        actions[0] = ProposedAction({
            target: address(governance),
            data: abi.encodeCall(IGovernanceUpgrade.upgradeStrategy, (address(receiverStrategy))),
            value: 0
        });
        vm.prank(whale);
        uint256 proposalId = governance.propose(actions, "switch to receiver");

        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Qualified));

        vm.warp(block.timestamp + 1);
        governance.execute(proposalId);
        assertEq(governance.governanceParameters().params.strategy, address(receiverStrategy));

        // local governance is fail-closed after the switch
        vm.expectRevert(abi.encodeWithSelector(MixinVoting.GovLowVotingPower.selector, 0, PROPOSAL_THRESHOLD));
        governance.propose(actions, "post-switch local proposal");

        // cross-chain receiving is unaffected by the switch
        ProposedAction[] memory incrementActions = new ProposedAction[](1);
        incrementActions[0] = _incrementAction();
        bytes memory payload = abi.encode(
            CrossChainPayload({targetWormholeChainId: TARGET_CHAIN, proposalId: 1, actions: incrementActions})
        );
        CoreBridgeVM memory vaa = CoreBridgeVM({
            version: 1,
            timestamp: uint32(block.timestamp),
            nonce: 0,
            emitterChainId: CHAIN_ID_ETHEREUM,
            emitterAddress: bytes32(uint256(uint160(address(governance)))),
            sequence: 0,
            consistencyLevel: 202,
            payload: payload,
            guardianSetIndex: 0,
            signatures: new GuardianSignature[](0),
            hash: keccak256(abi.encode(payload, uint64(0)))
        });
        vm.mockCall(wormhole, abi.encodeWithSelector(ICoreBridge.parseAndVerifyVM.selector), abi.encode(vaa, true, ""));
        governance.receiveMessage("");
        assertEq(counter.value(), 1);
    }

    function _incrementAction() private view returns (ProposedAction memory) {
        return ProposedAction({target: address(counter), data: abi.encodeCall(Counter.increment, ()), value: 0});
    }

    function _incrementActions() private view returns (ProposedAction[] memory) {
        ProposedAction[] memory actions = new ProposedAction[](1);
        actions[0] = _incrementAction();
        return actions;
    }
}
