// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;
import {IGovernanceStrategy} from "../../contracts/governance/interfaces/IGovernanceStrategy.sol";
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

    function setUp() public {
        strategy = new RigoblockGovernanceStrategy(STAKING, WORMHOLE, LOCAL_CHAIN_ID);
        vm.mockCall(WORMHOLE, abi.encodeWithSelector(ICoreBridge.messageFee.selector), abi.encode(FEE));
        vm.mockCall(STAKING, abi.encodeWithSelector(IStorage.epochDurationInSeconds.selector), abi.encode(7 days));
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getCurrentEpochEarliestEndTimeInSeconds.selector),
            abi.encode(block.timestamp + 100)
        );
    }

    function _action(
        address target,
        bytes memory data,
        uint256 value
    ) private pure returns (IGovernanceVoting.ProposedAction memory) {
        return IGovernanceVoting.ProposedAction({target: target, data: data, value: value});
    }

    function _actions(
        IGovernanceVoting.ProposedAction memory action
    ) private pure returns (IGovernanceVoting.ProposedAction[] memory) {
        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](1);
        actions[0] = action;
        return actions;
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
            abi.encodeWithSelector(ICoreBridge.publishMessage.selector, uint32(0), _payload(targetChainId), uint8(202));
    }

    function _mockSupply(uint256 supply) private {
        vm.mockCall(STAKING, abi.encodeWithSelector(IStaking.getGrgContract.selector), abi.encode(GRG));
        vm.mockCall(GRG, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(supply));
    }

    function test_beforePropose_NonWormhole_Passes() public {
        IGovernanceVoting.ProposedAction memory action = _action(TARGET, "", 0);
        IGovernanceVoting.ProposedAction[] memory result = strategy.beforePropose(_actions(action));
        assertEq(result[0].target, action.target);
        assertEq(result[0].data, action.data);
        assertEq(result[0].value, action.value);
    }

    function test_beforePropose_WormholeCorrect_Passes() public {
        IGovernanceVoting.ProposedAction[] memory result = strategy.beforePropose(
            _actions(_action(WORMHOLE, _wormholeData(TARGET_CHAIN_ID), 0))
        );
        assertEq(result[0].target, WORMHOLE);
    }

    function test_beforePropose_WormholeInvalidData_Reverts() public {
        bytes memory data = abi.encodePacked(bytes4(keccak256("unknown()")));
        vm.expectRevert(IGovernanceStrategy.GovCrosschainInvalidData.selector);
        strategy.beforePropose(_actions(_action(WORMHOLE, data, 0)));
    }

    function test_beforePropose_WormholeTargetSelf_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IGovernanceStrategy.GovCrosschainTargetSelf.selector, LOCAL_CHAIN_ID));
        strategy.beforePropose(_actions(_action(WORMHOLE, _wormholeData(LOCAL_CHAIN_ID), 0)));
    }

    function test_beforePropose_WormholeNonZeroValue_Reverts() public {
        uint256 value = 0.5 ether;
        vm.expectRevert(abi.encodeWithSelector(IGovernanceStrategy.GovCrosschainInvalidValue.selector, value));
        strategy.beforePropose(_actions(_action(WORMHOLE, _wormholeData(TARGET_CHAIN_ID), value)));
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
            uint8(202)
        );
        vm.expectRevert(abi.encodeWithSelector(IGovernanceStrategy.GovCrosschainInvalidValue.selector, value));
        strategy.beforePropose(_actions(_action(WORMHOLE, data, 0)));
    }

    function test_beforePropose_WormholeNonFinalizedConsistencyLevel_Reverts() public {
        // Wormhole EVM semantics: 200 = instant, 201 = safe; governance messages require 202 = finalized
        uint8[2] memory levels = [uint8(200), uint8(201)];
        for (uint256 i = 0; i < levels.length; i++) {
            bytes memory data = abi.encodeWithSelector(
                ICoreBridge.publishMessage.selector,
                uint32(0),
                _payload(TARGET_CHAIN_ID),
                levels[i]
            );
            vm.expectRevert(
                abi.encodeWithSelector(IGovernanceStrategy.GovCrosschainInvalidConsistencyLevel.selector, levels[i])
            );
            strategy.beforePropose(_actions(_action(WORMHOLE, data, 0)));
        }
    }

    function test_beforeExecute_NonWormhole_ReturnsUnchanged() public {
        IGovernanceVoting.ProposedAction memory action = _action(TARGET, "", 0.123 ether);
        IGovernanceVoting.ProposedAction[] memory result = strategy.beforeExecute(_actions(action));
        assertEq(result[0].target, action.target);
        assertEq(result[0].data, action.data);
        assertEq(result[0].value, action.value);
    }

    function test_beforeExecute_Wormhole_ReturnsFee() public {
        IGovernanceVoting.ProposedAction memory action = _action(WORMHOLE, _wormholeData(TARGET_CHAIN_ID), 0);
        IGovernanceVoting.ProposedAction[] memory result = strategy.beforeExecute(_actions(action));
        assertEq(result[0].target, WORMHOLE);
        assertEq(result[0].value, FEE);
    }

    function test_beforeExecute_Wormhole_OverridesProposerValue() public {
        // Wormhole's publishMessage requires msg.value == messageFee(), so any wrapper value
        // set at proposal time must be replaced by the fee rather than added to it.
        IGovernanceVoting.ProposedAction memory action = _action(WORMHOLE, _wormholeData(TARGET_CHAIN_ID), 1 ether);
        IGovernanceVoting.ProposedAction[] memory result = strategy.beforeExecute(_actions(action));
        assertEq(result[0].value, FEE);
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

    function test_VotingTimestamps_Timestamp_FreshEpoch_StartsAtEpochEnd() public {
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getCurrentEpochEarliestEndTimeInSeconds.selector),
            abi.encode(block.timestamp + 100)
        );
        (uint256 startBlockOrTime, uint256 endBlockOrTime) = strategy.votingTimestamps(TimeType.Timestamp);
        assertEq(startBlockOrTime, block.timestamp + 100);
        assertEq(endBlockOrTime, startBlockOrTime + 7 days);
    }

    function test_VotingTimestamps_Timestamp_StaleEpoch_Reverts() public {
        // outside the propose path a stale clock cannot schedule a window; the roll happens
        // in beforePropose instead
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getCurrentEpochEarliestEndTimeInSeconds.selector),
            abi.encode(block.timestamp - 1)
        );
        vm.expectRevert(IGovernanceStrategy.GovEpochNotFinalized.selector);
        strategy.votingTimestamps(TimeType.Timestamp);
    }

    function test_BeforePropose_StaleEpoch_Rolls() public {
        StakingClockStub clock = new StakingClockStub(block.timestamp - 1);
        RigoblockGovernanceStrategy clocked = new RigoblockGovernanceStrategy(address(clock), WORMHOLE, LOCAL_CHAIN_ID);
        clocked.beforePropose(_actions(_action(TARGET, "", 0)));
        assertEq(clock.endEpochCalls(), 1);
    }

    function test_BeforePropose_StaleEpoch_EndEpochNotApplied_Reverts() public {
        // if the staking clock does not move forward, the proposal cannot be scheduled rather
        // than starting inside a dead epoch
        StakingClockFrozenStub clock = new StakingClockFrozenStub(block.timestamp - 1);
        RigoblockGovernanceStrategy clocked = new RigoblockGovernanceStrategy(address(clock), WORMHOLE, LOCAL_CHAIN_ID);
        vm.expectRevert(IGovernanceStrategy.GovEpochNotFinalized.selector);
        clocked.beforePropose(_actions(_action(TARGET, "", 0)));
    }

    function test_BeforeVote_FreshEpoch_ReturnsEpochEnd() public {
        uint256 epochEnd = strategy.beforeVote(0);
        assertEq(epochEnd, block.timestamp + 100);
    }

    function test_BeforeVote_MatchingStoredEpoch_Passes() public {
        assertEq(strategy.beforeVote(block.timestamp + 100), block.timestamp + 100);
    }

    function test_BeforeVote_MismatchedStoredEpoch_Reverts() public {
        uint256 storedEpochEnd = block.timestamp + 42;
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceStrategy.GovVotingEpochMismatch.selector,
                block.timestamp + 100,
                storedEpochEnd
            )
        );
        strategy.beforeVote(storedEpochEnd);
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
            abi.encodeWithSelector(IGovernanceStrategy.GovStrategyInvalidTimeType.selector, TimeType.Blocknumber)
        );
        strategy.getProposalState(proposal, 100, 0, TimeType.Blocknumber);
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
            uint256(strategy.getProposalState(proposal, 100, 0, TimeType.Timestamp)),
            uint256(ProposalStatus.Pending)
        );

        proposal.startBlockOrTime = block.timestamp - 2;
        proposal.endBlockOrTime = block.timestamp - 1;
        proposal.votesFor = 200;
        assertEq(
            uint256(strategy.getProposalState(proposal, 100, 0, TimeType.Timestamp)),
            uint256(ProposalStatus.Succeeded)
        );
    }

    /// @dev Qualified is evaluated against the snapshotted denominator passed by the governance,
    ///      never a live staking read, and requires the same vote ratio as execution.
    function test_QualifiedConsensus_UsesSnapshotAndVoteRatio() public {
        vm.warp(block.timestamp + 1000);

        IGovernanceState.Proposal memory proposal = IGovernanceState.Proposal({
            actionsLength: 1,
            startBlockOrTime: block.timestamp - 2,
            endBlockOrTime: block.timestamp + 100,
            votesFor: 400,
            votesAgainst: 0,
            votesAbstain: 0,
            executed: false
        });

        // two-thirds of the 300-token snapshot, no opposition: Qualified
        assertEq(
            uint256(strategy.getProposalState(proposal, 100, 300, TimeType.Timestamp)),
            uint256(ProposalStatus.Qualified)
        );

        // same votes against a larger snapshot: below two-thirds, stays Active
        assertEq(
            uint256(strategy.getProposalState(proposal, 100, 601, TimeType.Timestamp)),
            uint256(ProposalStatus.Active)
        );

        // boundary is strict: exactly two-thirds does not qualify
        proposal.votesFor = 200;
        assertEq(
            uint256(strategy.getProposalState(proposal, 100, 300, TimeType.Timestamp)),
            uint256(ProposalStatus.Active)
        );

        // superquorum of the snapshot but a failing vote ratio: cannot close early, and cannot
        // qualify a proposal that would be Defeated at the deadline
        proposal.votesFor = 400;
        proposal.votesAgainst = 200;
        assertEq(
            uint256(strategy.getProposalState(proposal, 100, 300, TimeType.Timestamp)),
            uint256(ProposalStatus.Active)
        );
        vm.warp(block.timestamp + 200);
        assertEq(
            uint256(strategy.getProposalState(proposal, 100, 300, TimeType.Timestamp)),
            uint256(ProposalStatus.Defeated)
        );
    }

    function test_ProposalThreshold_AtBounds_Passes() public {
        _mockSupply(10_000_000e18);
        strategy.assertValidProposalThreshold(100_000e18);
        strategy.assertValidProposalThreshold(200_000e18);
    }

    function test_ProposalThreshold_BelowFloor_Reverts() public {
        _mockSupply(10_000_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceStrategy.GovStrategyInvalidProposalThreshold.selector,
                99_999e18,
                100_000e18,
                200_000e18
            )
        );
        strategy.assertValidProposalThreshold(99_999e18);
    }

    function test_ProposalThreshold_AboveCap_Reverts() public {
        _mockSupply(10_000_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceStrategy.GovStrategyInvalidProposalThreshold.selector,
                200_001e18,
                100_000e18,
                200_000e18
            )
        );
        strategy.assertValidProposalThreshold(200_001e18);
    }

    function test_QuorumThreshold_AtBounds_Passes() public {
        _mockSupply(10_000_000e18);
        strategy.assertValidQuorumThreshold(400_000e18);
        strategy.assertValidQuorumThreshold(1_000_000e18);
    }

    function test_QuorumThreshold_BelowFloor_Reverts() public {
        _mockSupply(10_000_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceStrategy.GovStrategyInvalidQuorumThreshold.selector,
                399_999e18,
                400_000e18,
                1_000_000e18
            )
        );
        strategy.assertValidQuorumThreshold(399_999e18);
    }

    function test_QuorumThreshold_AboveCap_Reverts() public {
        _mockSupply(10_000_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceStrategy.GovStrategyInvalidQuorumThreshold.selector,
                1_000_001e18,
                400_000e18,
                1_000_000e18
            )
        );
        strategy.assertValidQuorumThreshold(1_000_001e18);
    }

    function test_WormholeConfig_Readable() public {
        assertEq(strategy.wormhole(), WORMHOLE);
        assertEq(strategy.wormholeChainId(), LOCAL_CHAIN_ID);
    }
}

/// @dev Minimal staking clock for epoch-roll tests: endEpoch advances the epoch end.
contract StakingClockStub {
    uint256 public epochEnd;
    uint256 public endEpochCalls;

    constructor(uint256 epochEnd_) {
        epochEnd = epochEnd_;
    }

    function getCurrentEpochEarliestEndTimeInSeconds() external view returns (uint256) {
        return epochEnd;
    }

    function endEpoch() external virtual returns (uint256) {
        endEpochCalls++;
        epochEnd = block.timestamp + 7 days;
        return 0;
    }
}

/// @dev A staking clock whose endEpoch does not move the epoch forward.
contract StakingClockFrozenStub is StakingClockStub {
    constructor(uint256 epochEnd_) StakingClockStub(epochEnd_) {}

    function endEpoch() external virtual override returns (uint256) {
        endEpochCalls++;
        return 0;
    }
}
