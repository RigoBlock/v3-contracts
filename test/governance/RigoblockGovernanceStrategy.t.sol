// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;
import {GovernanceMode} from "../../contracts/governance/strategies/RigoblockGovernanceStrategy.sol";
import {CrossChainPayload, ProposalStatus} from "../../contracts/governance/types/GovernanceTypes.sol";

import {Test} from "forge-std/Test.sol";
import {ICoreBridge} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";
import {IERC20} from "../../contracts/tokens/ERC20/IERC20.sol";
import {IGovernanceState} from "../../contracts/governance/interfaces/governance/IGovernanceState.sol";
import {IGovernanceVoting} from "../../contracts/governance/interfaces/governance/IGovernanceVoting.sol";
import {IRigoblockGovernanceFactory} from "../../contracts/governance/interfaces/IRigoblockGovernanceFactory.sol";
import {RigoblockGovernanceStrategy} from "../../contracts/governance/strategies/RigoblockGovernanceStrategy.sol";
import {TimeType} from "../../contracts/governance/types/TimeType.sol";
import {IStorage} from "../../contracts/staking/interfaces/IStorage.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";

contract RigoblockGovernanceStrategyTest is Test {
    address internal constant STAKING = address(0x1111);
    address internal constant GRG = address(0x2222);
    address internal constant TARGET = address(0x3333);
    address internal constant WORMHOLE = address(0x4444);
    uint16 internal constant LOCAL_CHAIN_ID = 2;
    uint16 internal constant TARGET_CHAIN_ID = 47;
    uint256 internal constant FEE = 0.001 ether;

    RigoblockGovernanceStrategy internal strategy;
    RigoblockGovernanceStrategy internal senderStrategy;

    function setUp() public {
        strategy = new RigoblockGovernanceStrategy(STAKING, WORMHOLE, LOCAL_CHAIN_ID, GovernanceMode.Dual);
        senderStrategy = new RigoblockGovernanceStrategy(STAKING, WORMHOLE, LOCAL_CHAIN_ID, GovernanceMode.Sender);
        vm.mockCall(WORMHOLE, abi.encodeWithSelector(ICoreBridge.messageFee.selector), abi.encode(FEE));
        vm.mockCall(STAKING, abi.encodeWithSelector(IStorage.epochDurationInSeconds.selector), abi.encode(7 days));
    }

    function _action(
        address target,
        bytes memory data,
        uint256 value
    ) private pure returns (IGovernanceVoting.ProposedAction memory) {
        return IGovernanceVoting.ProposedAction({target: target, data: data, value: value});
    }

    function _payload(uint16 targetChainId) private pure returns (bytes memory) {
        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](1);
        actions[0] = _action(TARGET, "", 0);
        CrossChainPayload memory crossChainPayload = CrossChainPayload({
            targetWormholeChainId: targetChainId,
            proposalId: 1,
            actions: actions
        });
        return abi.encode(crossChainPayload);
    }

    function _wormholeData(uint16 targetChainId) private pure returns (bytes memory) {
        return
            abi.encodeWithSelector(ICoreBridge.publishMessage.selector, uint32(0), _payload(targetChainId), uint8(200));
    }

    function _mockSupply(uint256 supply) private {
        vm.mockCall(STAKING, abi.encodeWithSelector(IStaking.getGrgContract.selector), abi.encode(GRG));
        vm.mockCall(GRG, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(supply));
    }

    function test_beforePropose_NonWormhole_Passes() public {
        IGovernanceVoting.ProposedAction memory action = _action(TARGET, "", 0);
        IGovernanceVoting.ProposedAction memory result = strategy.beforePropose(action);
        assertEq(result.target, action.target);
        assertEq(result.data, action.data);
        assertEq(result.value, action.value);
    }

    function test_beforePropose_WormholeCorrect_Passes() public {
        IGovernanceVoting.ProposedAction memory result = senderStrategy.beforePropose(
            _action(WORMHOLE, _wormholeData(TARGET_CHAIN_ID), 0)
        );
        assertEq(result.target, WORMHOLE);
    }

    function test_beforePropose_WormholeAction_DualMode_Reverts() public {
        vm.expectRevert(RigoblockGovernanceStrategy.GovCrosschainNotSender.selector);
        strategy.beforePropose(_action(WORMHOLE, _wormholeData(TARGET_CHAIN_ID), 0));
    }

    function test_beforePropose_WormholeInvalidData_Reverts() public {
        bytes memory data = abi.encodePacked(bytes4(keccak256("unknown()")));
        vm.expectRevert(RigoblockGovernanceStrategy.GovCrosschainInvalidData.selector);
        senderStrategy.beforePropose(_action(WORMHOLE, data, 0));
    }

    function test_beforePropose_WormholeTargetSelf_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(RigoblockGovernanceStrategy.GovCrosschainTargetSelf.selector, LOCAL_CHAIN_ID)
        );
        senderStrategy.beforePropose(_action(WORMHOLE, _wormholeData(LOCAL_CHAIN_ID), 0));
    }

    function test_beforePropose_WormholeNonZeroValue_Reverts() public {
        uint256 value = 0.5 ether;
        vm.expectRevert(abi.encodeWithSelector(RigoblockGovernanceStrategy.GovCrosschainInvalidValue.selector, value));
        senderStrategy.beforePropose(_action(WORMHOLE, _wormholeData(TARGET_CHAIN_ID), value));
    }

    function test_beforePropose_WormholeNonZeroInnerActionValue_Reverts() public {
        uint256 value = 0.5 ether;
        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](1);
        actions[0] = _action(TARGET, "", value);
        CrossChainPayload memory crossChainPayload = CrossChainPayload({
            targetWormholeChainId: TARGET_CHAIN_ID,
            proposalId: 1,
            actions: actions
        });
        bytes memory data = abi.encodeWithSelector(
            ICoreBridge.publishMessage.selector,
            uint32(0),
            abi.encode(crossChainPayload),
            uint8(200)
        );
        vm.expectRevert(abi.encodeWithSelector(RigoblockGovernanceStrategy.GovCrosschainInvalidValue.selector, value));
        senderStrategy.beforePropose(_action(WORMHOLE, data, 0));
    }

    function test_beforePropose_WormholeNonFinalizedConsistencyLevel_Reverts() public {
        // 1 = "confirmed": guardians attest without Ethereum finality, which governance messages must not use
        bytes memory data = abi.encodeWithSelector(
            ICoreBridge.publishMessage.selector,
            uint32(0),
            _payload(TARGET_CHAIN_ID),
            uint8(1)
        );
        vm.expectRevert(
            abi.encodeWithSelector(RigoblockGovernanceStrategy.GovCrosschainInvalidConsistencyLevel.selector, uint8(1))
        );
        senderStrategy.beforePropose(_action(WORMHOLE, data, 0));
    }

    function test_beforeExecute_NonWormhole_ReturnsUnchanged() public {
        IGovernanceVoting.ProposedAction memory action = _action(TARGET, "", 0.123 ether);
        IGovernanceVoting.ProposedAction memory result = strategy.beforeExecute(action);
        assertEq(result.target, action.target);
        assertEq(result.data, action.data);
        assertEq(result.value, action.value);
    }

    function test_beforeExecute_Wormhole_ReturnsFee() public {
        IGovernanceVoting.ProposedAction memory action = _action(WORMHOLE, _wormholeData(TARGET_CHAIN_ID), 0);
        IGovernanceVoting.ProposedAction memory result = senderStrategy.beforeExecute(action);
        assertEq(result.target, WORMHOLE);
        assertEq(result.value, FEE);
    }

    function test_beforeExecute_Wormhole_OverridesProposerValue() public {
        // Wormhole's publishMessage requires msg.value == messageFee(), so any wrapper value
        // set at proposal time must be replaced by the fee rather than added to it.
        IGovernanceVoting.ProposedAction memory action = _action(WORMHOLE, _wormholeData(TARGET_CHAIN_ID), 1 ether);
        IGovernanceVoting.ProposedAction memory result = senderStrategy.beforeExecute(action);
        assertEq(result.value, FEE);
    }

    function test_beforeExecute_Wormhole_DualMode_PassesThrough() public {
        // Unreachable in practice (Dual beforePropose reverts wormhole actions): the Dual
        // branch leaves any action unchanged.
        IGovernanceVoting.ProposedAction memory action = _action(WORMHOLE, _wormholeData(TARGET_CHAIN_ID), 0);
        IGovernanceVoting.ProposedAction memory result = strategy.beforeExecute(action);
        assertEq(result.target, WORMHOLE);
        assertEq(result.value, 0);
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
            abi.encodeWithSelector(
                RigoblockGovernanceStrategy.GovStrategyInvalidTimeType.selector,
                TimeType.Blocknumber
            )
        );
        strategy.assertValidInitParams(params);
    }

    function test_VotingTimestamps_Blocknumber_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                RigoblockGovernanceStrategy.GovStrategyInvalidTimeType.selector,
                TimeType.Blocknumber
            )
        );
        strategy.votingTimestamps(TimeType.Blocknumber);
    }

    function test_VotingTimestamps_Timestamp_StartsNextTimestamp() public {
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getCurrentEpochEarliestEndTimeInSeconds.selector),
            abi.encode(block.timestamp - 1)
        );
        (uint256 startBlockOrTime, uint256 endBlockOrTime) = strategy.votingTimestamps(TimeType.Timestamp);
        assertEq(startBlockOrTime, block.timestamp + 1);
        assertEq(endBlockOrTime, startBlockOrTime + 7 days);
    }

    function test_GetProposalState_Blocknumber_Reverts() public {
        IGovernanceState.Proposal memory proposal = IGovernanceState.Proposal({
            actionsLength: 1,
            startBlockOrTime: block.timestamp + 1,
            endBlockOrTime: block.timestamp + 100,
            votesFor: 0,
            votesAgainst: 0,
            votesAbstain: 0,
            executed: false
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                RigoblockGovernanceStrategy.GovStrategyInvalidTimeType.selector,
                TimeType.Blocknumber
            )
        );
        strategy.getProposalState(proposal, 100, TimeType.Blocknumber);
    }

    function test_GetProposalState_Timestamp_ComparesTimestamp() public {
        vm.warp(block.timestamp + 100);

        IGovernanceState.Proposal memory proposal = IGovernanceState.Proposal({
            actionsLength: 1,
            startBlockOrTime: block.timestamp + 1,
            endBlockOrTime: block.timestamp + 100,
            votesFor: 0,
            votesAgainst: 0,
            votesAbstain: 0,
            executed: false
        });
        assertEq(
            uint256(strategy.getProposalState(proposal, 100, TimeType.Timestamp)),
            uint256(ProposalStatus.Pending)
        );

        proposal.startBlockOrTime = block.timestamp - 2;
        proposal.endBlockOrTime = block.timestamp - 1;
        proposal.votesFor = 200;
        assertEq(
            uint256(strategy.getProposalState(proposal, 100, TimeType.Timestamp)),
            uint256(ProposalStatus.Succeeded)
        );
    }

    function test_ProposalThreshold_Mainnet_AtBounds_Passes() public {
        vm.chainId(1);
        _mockSupply(10_000_000e18);
        strategy.assertValidProposalThreshold(100_000e18);
        strategy.assertValidProposalThreshold(200_000e18);
    }

    function test_ProposalThreshold_Mainnet_BelowFloor_Reverts() public {
        vm.chainId(1);
        _mockSupply(10_000_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                RigoblockGovernanceStrategy.GovStrategyInvalidProposalThreshold.selector,
                99_999e18,
                100_000e18,
                200_000e18
            )
        );
        strategy.assertValidProposalThreshold(99_999e18);
    }

    function test_ProposalThreshold_Mainnet_AboveCap_Reverts() public {
        vm.chainId(1);
        _mockSupply(10_000_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                RigoblockGovernanceStrategy.GovStrategyInvalidProposalThreshold.selector,
                200_001e18,
                100_000e18,
                200_000e18
            )
        );
        strategy.assertValidProposalThreshold(200_001e18);
    }

    function test_QuorumThreshold_Mainnet_AtBounds_Passes() public {
        vm.chainId(1);
        _mockSupply(10_000_000e18);
        strategy.assertValidQuorumThreshold(400_000e18);
        strategy.assertValidQuorumThreshold(1_000_000e18);
    }

    function test_QuorumThreshold_Mainnet_BelowFloor_Reverts() public {
        vm.chainId(1);
        _mockSupply(10_000_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                RigoblockGovernanceStrategy.GovStrategyInvalidQuorumThreshold.selector,
                399_999e18,
                400_000e18,
                1_000_000e18
            )
        );
        strategy.assertValidQuorumThreshold(399_999e18);
    }

    function test_QuorumThreshold_Mainnet_AboveCap_Reverts() public {
        vm.chainId(1);
        _mockSupply(10_000_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                RigoblockGovernanceStrategy.GovStrategyInvalidQuorumThreshold.selector,
                1_000_001e18,
                400_000e18,
                1_000_000e18
            )
        );
        strategy.assertValidQuorumThreshold(1_000_001e18);
    }

    function test_ProposalThreshold_Altchain_WithinHardLimits_Passes() public {
        // derived supply limits (10k/20k) are below the altchain hard limits (20k/100k)
        _mockSupply(1_000_000e18);
        strategy.assertValidProposalThreshold(20_000e18);
        strategy.assertValidProposalThreshold(100_000e18);
    }

    function test_ProposalThreshold_Altchain_BelowHardFloor_Reverts() public {
        _mockSupply(1_000_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                RigoblockGovernanceStrategy.GovStrategyInvalidProposalThreshold.selector,
                15_000e18,
                20_000e18,
                100_000e18
            )
        );
        strategy.assertValidProposalThreshold(15_000e18);
    }

    function test_QuorumThreshold_Altchain_WithinHardLimits_Passes() public {
        // derived supply limits (40k/100k) are below the altchain hard limits (100k/400k)
        _mockSupply(1_000_000e18);
        strategy.assertValidQuorumThreshold(100_000e18);
        strategy.assertValidQuorumThreshold(400_000e18);
    }

    function test_QuorumThreshold_Altchain_BelowHardFloor_Reverts() public {
        _mockSupply(1_000_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                RigoblockGovernanceStrategy.GovStrategyInvalidQuorumThreshold.selector,
                50_000e18,
                100_000e18,
                400_000e18
            )
        );
        strategy.assertValidQuorumThreshold(50_000e18);
    }

    /// @dev Receiver-mode strategies must work with no staking contract at all (e.g. HyperEVM),
    ///     so these tests deploy with a zero staking proxy and no staking mocks.
    function _receiverStrategy() private returns (RigoblockGovernanceStrategy) {
        return new RigoblockGovernanceStrategy(address(0), WORMHOLE, TARGET_CHAIN_ID, GovernanceMode.Receiver);
    }

    function test_Receiver_BeforePropose_Reverts() public {
        RigoblockGovernanceStrategy receiver = _receiverStrategy();
        vm.expectRevert(RigoblockGovernanceStrategy.GovLocalGovernanceDisabled.selector);
        receiver.beforePropose(_action(TARGET, "", 0));
    }

    function test_Receiver_BeforeExecute_Reverts() public {
        RigoblockGovernanceStrategy receiver = _receiverStrategy();
        vm.expectRevert(RigoblockGovernanceStrategy.GovLocalGovernanceDisabled.selector);
        receiver.beforeExecute(_action(TARGET, "", 0));
    }

    function test_Receiver_VotingTimestamps_Reverts() public {
        RigoblockGovernanceStrategy receiver = _receiverStrategy();
        vm.expectRevert(RigoblockGovernanceStrategy.GovLocalGovernanceDisabled.selector);
        receiver.votingTimestamps(TimeType.Timestamp);
    }

    function test_Receiver_GetVotingPower_ReturnsZero() public {
        RigoblockGovernanceStrategy receiver = _receiverStrategy();
        assertEq(receiver.getVotingPower(address(0x9999)), 0);
    }

    function test_Receiver_GetProposalState_ReturnsDefeatedWithoutStaking() public {
        RigoblockGovernanceStrategy receiver = _receiverStrategy();
        // values are irrelevant: receiver mode returns Defeated without inspecting the proposal
        IGovernanceState.Proposal memory proposal = IGovernanceState.Proposal({
            actionsLength: 1,
            startBlockOrTime: 1,
            endBlockOrTime: 2,
            votesFor: 100,
            votesAgainst: 0,
            votesAbstain: 0,
            executed: false
        });
        assertEq(uint256(receiver.getProposalState(proposal, 1, TimeType.Timestamp)), uint256(ProposalStatus.Defeated));
    }

    function test_Receiver_VotingPeriod_ReturnsDefaultWithoutStaking() public {
        RigoblockGovernanceStrategy receiver = _receiverStrategy();
        assertEq(receiver.votingPeriod(), 7 days);
    }

    function test_Receiver_AssertValidInitParams_SkipsThresholdValidation() public {
        RigoblockGovernanceStrategy receiver = _receiverStrategy();
        IRigoblockGovernanceFactory.Parameters memory params = IRigoblockGovernanceFactory.Parameters({
            implementation: address(0),
            governanceStrategy: address(receiver),
            proposalThreshold: 0,
            quorumThreshold: 0,
            timeType: TimeType.Timestamp,
            name: "Rigoblock Governance"
        });
        // zero thresholds would revert on any staking-backed strategy; receiver accepts them
        receiver.assertValidInitParams(params);
    }

    function test_Receiver_AssertValidInitParams_Blocknumber_Reverts() public {
        RigoblockGovernanceStrategy receiver = _receiverStrategy();
        IRigoblockGovernanceFactory.Parameters memory params = IRigoblockGovernanceFactory.Parameters({
            implementation: address(0),
            governanceStrategy: address(receiver),
            proposalThreshold: 0,
            quorumThreshold: 0,
            timeType: TimeType.Blocknumber,
            name: "Rigoblock Governance"
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                RigoblockGovernanceStrategy.GovStrategyInvalidTimeType.selector,
                TimeType.Blocknumber
            )
        );
        receiver.assertValidInitParams(params);
    }

    function test_Receiver_ThresholdValidators_NoOpWithoutStaking() public {
        RigoblockGovernanceStrategy receiver = _receiverStrategy();
        // any value accepted, no staking read: would revert if supply were consulted
        receiver.assertValidProposalThreshold(1);
        receiver.assertValidQuorumThreshold(type(uint256).max);
    }

    function test_Receiver_WormholeConfig_Readable() public {
        RigoblockGovernanceStrategy receiver = _receiverStrategy();
        assertEq(receiver.wormhole(), WORMHOLE);
        assertEq(receiver.wormholeChainId(), TARGET_CHAIN_ID);
    }
}
