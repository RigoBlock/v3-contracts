// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;
import {CrossChainPayload, ProposalStatus, ProposedAction, ProposalExtraData} from "../../contracts/governance/types/GovernanceTypes.sol";

import {Test} from "forge-std/Test.sol";
import {ICoreBridge} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";
import {IERC20} from "../../contracts/tokens/ERC20/IERC20.sol";
import {IGovernanceState} from "../../contracts/governance/interfaces/governance/IGovernanceState.sol";
import {IGovernanceStrategy} from "../../contracts/governance/interfaces/IGovernanceStrategy.sol";
import {IGovernanceUpgrade} from "../../contracts/governance/interfaces/governance/IGovernanceUpgrade.sol";
import {IGovernanceVoting} from "../../contracts/governance/interfaces/governance/IGovernanceVoting.sol";
import {IRigoblockGovernanceFactory} from "../../contracts/governance/interfaces/IRigoblockGovernanceFactory.sol";
import {RigoblockGovernance} from "../../contracts/governance/RigoblockGovernance.sol";
import {RigoblockGovernanceStrategy} from "../../contracts/governance/strategies/RigoblockGovernanceStrategy.sol";
import {TimeType} from "../../contracts/governance/types/TimeType.sol";
import {IStorage} from "../../contracts/staking/interfaces/IStorage.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {IStructs} from "../../contracts/staking/interfaces/IStructs.sol";

contract RigoblockGovernanceStrategyTest is Test {
    address internal constant STAKING = address(0x1111);
    address internal constant GRG = address(0x2222);
    address internal constant TARGET = address(0x3333);
    uint16 internal constant LOCAL_CHAIN_ID = 2;
    uint16 internal constant TARGET_CHAIN_ID = 47;
    uint256 internal constant FEE = 0.001 ether;

    address internal wormhole;
    RigoblockGovernanceStrategy internal strategy;

    function setUp() public {
        wormhole = makeAddr("wormhole");
        // enough code for the constructor's code.length check; chainId/messageFee are mocked
        vm.etch(wormhole, hex"00");
        vm.mockCall(wormhole, abi.encodeWithSelector(ICoreBridge.chainId.selector), abi.encode(LOCAL_CHAIN_ID));
        vm.mockCall(wormhole, abi.encodeWithSelector(ICoreBridge.messageFee.selector), abi.encode(FEE));
        strategy = new RigoblockGovernanceStrategy(STAKING, wormhole);
        vm.mockCall(STAKING, abi.encodeWithSelector(IStorage.epochDurationInSeconds.selector), abi.encode(7 days));
        // the roll target returns proper ABI data: a bare no-code call would revert in a way
        // that bypasses the strategy's try/catch (solc routes only call-level failures to catch)
        vm.mockCall(STAKING, abi.encodeWithSelector(IStaking.endEpoch.selector), abi.encode(uint256(0)));
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getCurrentEpochEarliestEndTimeInSeconds.selector),
            abi.encode(block.timestamp + 100)
        );
    }

    function _action(address target, bytes memory data, uint256 value) private pure returns (ProposedAction memory) {
        return ProposedAction({target: target, data: data, value: value});
    }

    function _actions(ProposedAction memory action) private pure returns (ProposedAction[] memory) {
        ProposedAction[] memory actions = new ProposedAction[](1);
        actions[0] = action;
        return actions;
    }

    function _payload(uint16 targetChainId) private pure returns (bytes memory) {
        ProposedAction[] memory actions = new ProposedAction[](1);
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
        ProposedAction memory action = _action(TARGET, "", 0);
        (ProposedAction[] memory result, uint256 startBlockOrTime, uint256 endBlockOrTime) = strategy.beforePropose(
            _actions(action)
        );
        assertEq(result[0].target, action.target);
        assertEq(result[0].data, action.data);
        assertEq(result[0].value, action.value);
        assertEq(startBlockOrTime, block.timestamp + 100);
        assertEq(endBlockOrTime, startBlockOrTime + 7 days - 1);
    }

    function test_beforePropose_WormholeCorrect_Passes() public {
        (ProposedAction[] memory result, , ) = strategy.beforePropose(
            _actions(_action(wormhole, _wormholeData(TARGET_CHAIN_ID), 0))
        );
        assertEq(result[0].target, wormhole);
    }

    function test_beforePropose_WormholeInvalidData_Reverts() public {
        bytes memory data = abi.encodePacked(bytes4(keccak256("unknown()")));
        vm.expectRevert(RigoblockGovernanceStrategy.GovCrosschainInvalidData.selector);
        strategy.beforePropose(_actions(_action(wormhole, data, 0)));
    }

    function test_beforePropose_WormholeTargetSelf_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(RigoblockGovernanceStrategy.GovCrosschainTargetSelf.selector, LOCAL_CHAIN_ID)
        );
        strategy.beforePropose(_actions(_action(wormhole, _wormholeData(LOCAL_CHAIN_ID), 0)));
    }

    function test_beforePropose_WormholeNonZeroValue_Reverts() public {
        uint256 value = 0.5 ether;
        vm.expectRevert(abi.encodeWithSelector(RigoblockGovernanceStrategy.GovCrosschainInvalidValue.selector, value));
        strategy.beforePropose(_actions(_action(wormhole, _wormholeData(TARGET_CHAIN_ID), value)));
    }

    function test_beforePropose_WormholeNonZeroInnerActionValue_Reverts() public {
        uint256 value = 0.5 ether;
        ProposedAction[] memory actions = new ProposedAction[](1);
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
        vm.expectRevert(abi.encodeWithSelector(RigoblockGovernanceStrategy.GovCrosschainInvalidValue.selector, value));
        strategy.beforePropose(_actions(_action(wormhole, data, 0)));
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
                abi.encodeWithSelector(
                    RigoblockGovernanceStrategy.GovCrosschainInvalidConsistencyLevel.selector,
                    levels[i]
                )
            );
            strategy.beforePropose(_actions(_action(wormhole, data, 0)));
        }
    }

    function test_beforeExecute_NonWormhole_ReturnsUnchanged() public {
        ProposedAction memory action = _action(TARGET, "", 0.123 ether);
        ProposedAction[] memory result = strategy.beforeExecute(_actions(action));
        assertEq(result[0].target, action.target);
        assertEq(result[0].data, action.data);
        assertEq(result[0].value, action.value);
    }

    function test_beforeExecute_Wormhole_ReturnsFee() public {
        ProposedAction memory action = _action(wormhole, _wormholeData(TARGET_CHAIN_ID), 0);
        ProposedAction[] memory result = strategy.beforeExecute(_actions(action));
        assertEq(result[0].target, wormhole);
        assertEq(result[0].value, FEE);
    }

    function test_beforeExecute_Wormhole_OverridesProposerValue() public {
        // Wormhole's publishMessage requires msg.value == messageFee(), so any wrapper value
        // set at proposal time must be replaced by the fee rather than added to it.
        ProposedAction memory action = _action(wormhole, _wormholeData(TARGET_CHAIN_ID), 1 ether);
        ProposedAction[] memory result = strategy.beforeExecute(_actions(action));
        assertEq(result[0].value, FEE);
    }

    function test_ValidateParams_Blocknumber_Reverts() public {
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
        strategy.validateParams(params);
    }

    function test_VotingTimestamps_FreshEpoch_StartsAtEpochEnd() public {
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getCurrentEpochEarliestEndTimeInSeconds.selector),
            abi.encode(block.timestamp + 100)
        );
        (, uint256 startBlockOrTime, uint256 endBlockOrTime) = strategy.beforePropose(_actions(_action(TARGET, "", 0)));
        assertEq(startBlockOrTime, block.timestamp + 100);
        assertEq(endBlockOrTime, startBlockOrTime + 7 days - 1);
    }

    function test_VotingTimestamps_StaleEpoch_FallsBackToCurrentTimestamp() public {
        // a stale clock with a stuck scheduler (endEpoch cannot complete): the window starts
        // at the current timestamp, so the proposal is Pending during the propose block
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getCurrentEpochEarliestEndTimeInSeconds.selector),
            abi.encode(block.timestamp - 1)
        );
        vm.mockCallRevert(STAKING, abi.encodeWithSelector(IStaking.endEpoch.selector), abi.encode("endEpoch bricked"));
        (, uint256 startBlockOrTime, uint256 endBlockOrTime) = strategy.beforePropose(_actions(_action(TARGET, "", 0)));
        assertEq(startBlockOrTime, block.timestamp);
        assertEq(endBlockOrTime, startBlockOrTime + 7 days - 1);
    }

    function test_BeforePropose_StaleEpoch_Rolls() public {
        StakingClockStub clock = new StakingClockStub(block.timestamp - 1);
        RigoblockGovernanceStrategy clocked = new RigoblockGovernanceStrategy(address(clock), wormhole);
        clocked.beforePropose(_actions(_action(TARGET, "", 0)));
        assertEq(clock.endEpochCalls(), 1);
    }

    function test_VotingPeriod_MinEpochMinusOne_CappedAtSevenDays() public {
        // the window is strictly-inside-one-epoch: min(epochDuration - 1, 7 days)
        assertEq(strategy.votingPeriod(), 7 days - 1);

        vm.mockCall(STAKING, abi.encodeWithSelector(IStorage.epochDurationInSeconds.selector), abi.encode(3 days));
        assertEq(strategy.votingPeriod(), 3 days - 1);

        vm.mockCall(STAKING, abi.encodeWithSelector(IStorage.epochDurationInSeconds.selector), abi.encode(14 days));
        assertEq(strategy.votingPeriod(), 7 days);
    }

    /// @dev An epoch duration below 2 seconds cannot host a one-second-margin window:
    ///     votingPeriod falls back to the 7-day constant.
    function test_VotingPeriod_EpochDurationBelowTwo_FallsBackToConstant() public {
        vm.mockCall(STAKING, abi.encodeWithSelector(IStorage.epochDurationInSeconds.selector), abi.encode(0));
        assertEq(strategy.votingPeriod(), 7 days);

        vm.mockCall(STAKING, abi.encodeWithSelector(IStorage.epochDurationInSeconds.selector), abi.encode(1));
        assertEq(strategy.votingPeriod(), 7 days);
    }

    /// @dev A broken staking view is not hidden behind a fallback: votingPeriod reverts.
    function test_VotingPeriod_UnreadableClock_Reverts() public {
        vm.mockCallRevert(
            STAKING,
            abi.encodeWithSelector(IStorage.epochDurationInSeconds.selector),
            abi.encode("staking bricked")
        );
        vm.expectRevert();
        strategy.votingPeriod();
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
        strategy.getProposalState(proposal, address(0), 100, 0, TimeType.Blocknumber);
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
            uint256(strategy.getProposalState(proposal, address(0), 100, 0, TimeType.Timestamp)),
            uint256(ProposalStatus.Pending)
        );

        proposal.startBlockOrTime = block.timestamp - 2;
        proposal.endBlockOrTime = block.timestamp - 1;
        proposal.votesFor = 200;
        assertEq(
            uint256(strategy.getProposalState(proposal, address(0), 100, 0, TimeType.Timestamp)),
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
            uint256(strategy.getProposalState(proposal, address(0), 100, 300, TimeType.Timestamp)),
            uint256(ProposalStatus.Qualified)
        );

        // same votes against a larger snapshot: below two-thirds, stays Active
        assertEq(
            uint256(strategy.getProposalState(proposal, address(0), 100, 601, TimeType.Timestamp)),
            uint256(ProposalStatus.Active)
        );

        // boundary is strict: exactly two-thirds does not qualify
        proposal.votesFor = 200;
        assertEq(
            uint256(strategy.getProposalState(proposal, address(0), 100, 300, TimeType.Timestamp)),
            uint256(ProposalStatus.Active)
        );

        // superquorum of the snapshot but a failing vote ratio: cannot close early, and cannot
        // qualify a proposal that would be Defeated at the deadline
        proposal.votesFor = 400;
        proposal.votesAgainst = 200;
        assertEq(
            uint256(strategy.getProposalState(proposal, address(0), 100, 300, TimeType.Timestamp)),
            uint256(ProposalStatus.Active)
        );
        vm.warp(block.timestamp + 200);
        assertEq(
            uint256(strategy.getProposalState(proposal, address(0), 100, 300, TimeType.Timestamp)),
            uint256(ProposalStatus.Defeated)
        );
    }

    function test_ProposalThreshold_AtBounds_Passes() public {
        _mockSupply(10_000_000e18);
        _assertThresholdsAtBoundsPass(100_000e18, 400_000e18);
        _assertThresholdsAtBoundsPass(200_000e18, 1_000_000e18);
    }

    function test_ProposalThreshold_BelowFloor_Reverts() public {
        _mockSupply(10_000_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernanceStrategy.GovStrategyInvalidProposalThreshold.selector, 99_999e18)
        );
        strategy.validateParams(_params(99_999e18, 400_000e18));
    }

    function test_ProposalThreshold_AboveCap_Reverts() public {
        _mockSupply(10_000_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernanceStrategy.GovStrategyInvalidProposalThreshold.selector, 200_001e18)
        );
        strategy.validateParams(_params(200_001e18, 400_000e18));
    }

    function test_QuorumThreshold_BelowFloor_Reverts() public {
        _mockSupply(10_000_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernanceStrategy.GovStrategyInvalidQuorumThreshold.selector, 399_999e18)
        );
        strategy.validateParams(_params(100_000e18, 399_999e18));
    }

    function test_QuorumThreshold_AboveCap_Reverts() public {
        _mockSupply(10_000_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernanceStrategy.GovStrategyInvalidQuorumThreshold.selector, 1_000_001e18)
        );
        strategy.validateParams(_params(100_000e18, 1_000_001e18));
    }

    function _params(
        uint256 proposalThreshold,
        uint256 quorumThreshold
    ) private view returns (IRigoblockGovernanceFactory.Parameters memory) {
        return
            IRigoblockGovernanceFactory.Parameters({
                implementation: address(0),
                governanceStrategy: address(strategy),
                proposalThreshold: proposalThreshold,
                quorumThreshold: quorumThreshold,
                timeType: TimeType.Timestamp,
                name: "Rigoblock Governance"
            });
    }

    function _assertThresholdsAtBoundsPass(uint256 proposalThreshold, uint256 quorumThreshold) private {
        strategy.validateParams(_params(proposalThreshold, quorumThreshold));
    }

    function test_WormholeConfig_Readable() public {
        assertEq(strategy.wormhole(), wormhole);
        // the local Wormhole chain id is not strategy state: it is read from the core contract
        assertEq(ICoreBridge(wormhole).chainId(), LOCAL_CHAIN_ID);
    }

    function test_Constructor_ZeroWormhole_Reverts() public {
        vm.expectRevert(RigoblockGovernanceStrategy.GovStrategyInvalidWormhole.selector);
        new RigoblockGovernanceStrategy(STAKING, address(0));
    }

    function test_Constructor_EoaWormhole_Reverts() public {
        vm.expectRevert(RigoblockGovernanceStrategy.GovStrategyInvalidWormhole.selector);
        new RigoblockGovernanceStrategy(STAKING, makeAddr("eoa"));
    }

    function test_Constructor_NonWormholeContract_Reverts() public {
        // a contract that does not implement chainId(): the probe call reverts
        address nonWormhole = address(new StakingClockStub(block.timestamp + 7 days));
        vm.expectRevert(RigoblockGovernanceStrategy.GovStrategyInvalidWormhole.selector);
        new RigoblockGovernanceStrategy(STAKING, nonWormhole);
    }

    function test_Constructor_ValidWormhole_Constructs() public {
        RigoblockGovernanceStrategy valid = new RigoblockGovernanceStrategy(STAKING, wormhole);
        assertEq(valid.wormhole(), wormhole);
    }

    /// @notice A governance proposal carrying a governance-self updateThresholds action with
    ///     out-of-bounds values passes propose and voting, and reverts at execution time:
    ///     updateThresholds validates the post-update parameters through the strategy.
    function test_UpdateThresholdsViaProposal_OutOfBounds_RevertsAtExecute() public {
        _mockSupply(10_000_000e18);
        address whale = makeAddr("whale");
        StrategyHarness governance = _stakingBackedGovernance(whale);

        vm.prank(whale);
        uint256 proposalId = governance.propose(
            _actions(
                _action(
                    address(governance),
                    abi.encodeCall(IGovernanceUpgrade.updateThresholds, (99_999e18, 400_000e18)),
                    0
                )
            ),
            "lower proposal threshold below floor"
        );
        _passAndWarpPastWindow(governance, whale, proposalId);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernanceStrategy.GovStrategyInvalidProposalThreshold.selector, 99_999e18)
        );
        governance.execute(proposalId);

        vm.prank(whale);
        proposalId = governance.propose(
            _actions(
                _action(
                    address(governance),
                    abi.encodeCall(IGovernanceUpgrade.updateThresholds, (150_000e18, 1_000_001e18)),
                    0
                )
            ),
            "raise quorum above cap"
        );
        _passAndWarpPastWindow(governance, whale, proposalId);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernanceStrategy.GovStrategyInvalidQuorumThreshold.selector, 1_000_001e18)
        );
        governance.execute(proposalId);
    }

    /// @notice Validation runs at execution time against the live supply: a proposal changing
    ///     only the quorum still validates the unchanged proposal threshold, which supply
    ///     inflation may have drifted out of range since the parameters were set.
    function test_UpdateThresholdsViaProposal_UnchangedThresholdDriftedOutOfBounds_RevertsAtExecute() public {
        _mockSupply(10_000_000e18);
        address whale = makeAddr("whale");
        StrategyHarness governance = _stakingBackedGovernance(whale);
        governance.setParams(100_000e18, 400_000e18);

        vm.prank(whale);
        uint256 proposalId = governance.propose(
            _actions(
                _action(
                    address(governance),
                    abi.encodeCall(IGovernanceUpgrade.updateThresholds, (100_000e18, 600_000e18)),
                    0
                )
            ),
            "only raise the quorum"
        );
        _passAndWarpPastWindow(governance, whale, proposalId);

        // supply doubles before execution: the unchanged 100k proposal threshold is now below
        // the 1% floor, so the post-update parameters fail validation
        _mockSupply(20_000_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernanceStrategy.GovStrategyInvalidProposalThreshold.selector, 100_000e18)
        );
        governance.execute(proposalId);
    }

    /// @dev Votes the whale's balance in favor and moves past the voting window so the
    ///      proposal reads Succeeded and can be executed.
    function _passAndWarpPastWindow(StrategyHarness governance, address voter, uint256 proposalId) private {
        IGovernanceState.Proposal memory proposal = governance.getProposalById(proposalId).proposal;
        vm.warp(proposal.startBlockOrTime + 1);
        vm.prank(voter);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        vm.warp(proposal.endBlockOrTime + 1);
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Succeeded));
    }

    /// @notice The voting window is stored at propose time as fixed pointers: re-reading it
    ///     after time passes returns the same values, never a rolling recomputation.
    function test_VotingWindow_FixedPointers_DoNotRoll() public {
        _mockSupply(10_000_000e18);
        address whale = makeAddr("whale");
        StrategyHarness governance = _stakingBackedGovernance(whale);

        vm.prank(whale);
        uint256 proposalId = governance.propose(_actions(_action(TARGET, "", 0)), "fixed window");
        IGovernanceState.Proposal memory proposal = governance.getProposalById(proposalId).proposal;
        uint256 start = proposal.startBlockOrTime;
        uint256 end = proposal.endBlockOrTime;
        assertEq(start, block.timestamp + 100);

        vm.warp(start + 1);
        assertEq(governance.getProposalById(proposalId).proposal.startBlockOrTime, start);
        assertEq(governance.getProposalById(proposalId).proposal.endBlockOrTime, end);

        vm.warp(end + 100 days);
        assertEq(governance.getProposalById(proposalId).proposal.startBlockOrTime, start);
        assertEq(governance.getProposalById(proposalId).proposal.endBlockOrTime, end);
    }

    /// @notice A proposal with in-bounds thresholds proposes, passes and executes; the stored
    ///     thresholds reflect the new values afterwards.
    function test_UpdateThresholdsViaProposal_InBounds_Executes() public {
        _mockSupply(10_000_000e18);
        address whale = makeAddr("whale");
        StrategyHarness governance = _stakingBackedGovernance(whale);

        vm.prank(whale);
        uint256 proposalId = governance.propose(
            _actions(
                _action(
                    address(governance),
                    abi.encodeCall(IGovernanceUpgrade.updateThresholds, (150_000e18, 500_000e18)),
                    0
                )
            ),
            "update thresholds"
        );

        // the staking clock is fresh in this test, so the window starts at the mocked epoch end
        vm.warp(governance.getProposalById(proposalId).proposal.startBlockOrTime + 1);
        vm.prank(whale);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        vm.warp(governance.getProposalById(proposalId).proposal.endBlockOrTime + 1);

        governance.execute(proposalId);
        assertEq(governance.proposalThreshold(), 150_000e18);
        assertEq(governance.quorum(0), 500_000e18);
    }

    /// @notice A proposal's quorum is frozen at propose time, not re-read at vote or execution
    ///     time: a proposal created under Q1 keeps being judged against Q1 after a later
    ///     proposal raises the global quorum to Q2, and only proposals created afterwards
    ///     snapshot Q2. The whale's 500k balance clears Q1 (400k) but not Q2 (600k), so the
    ///     frozen snapshot is observable in the outcome.
    function test_Quorum_FrozenAtProposeTime_NotRereadAtVoteOrExecution() public {
        _mockSupply(10_000_000e18);
        address whale = makeAddr("whale");
        StrategyHarness governance = _stakingBackedGovernance(whale);
        governance.setParams(100_000e18, 400_000e18);

        vm.startPrank(whale);
        uint256 proposalA = governance.propose(
            _actions(
                _action(
                    address(governance),
                    abi.encodeCall(IGovernanceUpgrade.updateThresholds, (100_000e18, 600_000e18)),
                    0
                )
            ),
            "raise the quorum to Q2"
        );
        uint256 proposalB = governance.propose(_actions(_action(TARGET, "", 0)), "created under Q1");
        vm.stopPrank();

        assertEq(governance.proposalQuorum(proposalA), 400_000e18);
        assertEq(governance.proposalQuorum(proposalB), 400_000e18);

        // both proposals share the mocked window: vote both, then pass and execute A
        vm.warp(governance.getProposalById(proposalA).proposal.startBlockOrTime + 1);
        vm.prank(whale);
        governance.castVote(proposalA, uint8(IGovernanceVoting.VoteType.For));
        vm.prank(whale);
        governance.castVote(proposalB, uint8(IGovernanceVoting.VoteType.For));
        vm.warp(governance.getProposalById(proposalA).proposal.endBlockOrTime + 1);
        governance.execute(proposalA);
        assertEq(governance.quorum(0), 600_000e18);

        // B was created under Q1: 500k does not reach Q2, yet B still succeeds against its
        // frozen Q1 — a live re-read would have judged it Defeated
        assertEq(governance.proposalQuorum(proposalB), 400_000e18);
        vm.warp(governance.getProposalById(proposalB).proposal.endBlockOrTime + 1);
        assertEq(uint256(governance.getProposalState(proposalB)), uint256(ProposalStatus.Succeeded));

        // C is created after A executed: it snapshots Q2, and the same 500k vote no longer
        // reaches quorum
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getCurrentEpochEarliestEndTimeInSeconds.selector),
            abi.encode(block.timestamp + 100)
        );
        vm.prank(whale);
        uint256 proposalC = governance.propose(_actions(_action(TARGET, "", 0)), "created under Q2");
        assertEq(governance.proposalQuorum(proposalC), 600_000e18);

        vm.warp(governance.getProposalById(proposalC).proposal.startBlockOrTime + 1);
        vm.prank(whale);
        governance.castVote(proposalC, uint8(IGovernanceVoting.VoteType.For));
        vm.warp(governance.getProposalById(proposalC).proposal.endBlockOrTime + 1);
        assertEq(uint256(governance.getProposalState(proposalC)), uint256(ProposalStatus.Defeated));
    }

    /// @notice Governance must stay operational even when the staking contract cannot roll a
    ///     finished epoch: the swallowed endEpoch revert leaves the clock stale, the window
    ///     falls back to starting at the current timestamp (Pending during the propose block,
    ///     voteable from the next), and the full propose/vote/execute flow still works.
    function test_EndEpochReverting_GovernanceStaysOperational() public {
        address whale = makeAddr("whale");
        StrategyHarness governance = _stakingBackedGovernance(whale);

        // stale clock, and endEpoch bricks when the roll is attempted
        _mockStaleClock();
        vm.mockCallRevert(STAKING, abi.encodeWithSelector(IStaking.endEpoch.selector), abi.encode("endEpoch bricked"));

        vm.prank(whale);
        uint256 proposalId = governance.propose(_actions(_action(TARGET, "", 0)), "bricked staking");
        IGovernanceState.Proposal memory proposal = governance.getProposalById(proposalId).proposal;
        assertEq(proposal.startBlockOrTime, block.timestamp);

        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Active));

        // past the (fallback) window the honest vote counts decide
        vm.warp(proposal.endBlockOrTime + 1);
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Succeeded));
        governance.execute(proposalId);
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Executed));
    }

    /// @notice With the epoch past its end and endEpoch reverting, proposing succeeds and the
    ///     proposal starts at the current timestamp rather than reverting.
    function test_Propose_StaleEpoch_EndEpochReverting_StartsCurrentTimestamp() public {
        address whale = makeAddr("whale");
        StrategyHarness governance = _stakingBackedGovernance(whale);

        _mockStaleClock();
        vm.mockCallRevert(STAKING, abi.encodeWithSelector(IStaking.endEpoch.selector), abi.encode("endEpoch bricked"));

        vm.prank(whale);
        uint256 proposalId = governance.propose(_actions(_action(TARGET, "", 0)), "stale clock");
        assertEq(governance.getProposalById(proposalId).proposal.startBlockOrTime, block.timestamp);
    }

    /// @notice While the staking epoch cannot roll, the delegated balances are frozen: a
    ///     delegation mid-stuck-epoch changes only the next-epoch balance, so voting power,
    ///     the beforeVote total and the qualified-majority denominator are all unchanged, and
    ///     the full propose/vote/vote/execute flow succeeds against the frozen snapshot.
    function test_StuckEpoch_BalancesFrozen_FlowConsistent() public {
        StakingStub staking = new StakingStub();
        RigoblockGovernanceStrategy stubStrategy = new RigoblockGovernanceStrategy(address(staking), wormhole);
        StrategyHarness governance = new StrategyHarness();
        governance.setStrategy(address(stubStrategy));
        governance.setParams(1, 1);

        address voter1 = makeAddr("voter1");
        address voter2 = makeAddr("voter2");
        staking.setOwnerDelegated(voter1, 1_200_000e18, 1_200_000e18);
        staking.setOwnerDelegated(voter2, 300_000e18, 300_000e18);
        staking.setGlobalDelegated(2_000_000e18, 2_000_000e18);

        // the epoch goes stale and cannot roll (e.g. unfinalized pools)
        staking.setEpochEnd(block.timestamp - 1);
        staking.brickEndEpoch();

        // (1) a delegation made mid-stuck-epoch lands in the next-epoch balance only:
        // voting power and the beforeVote total are unchanged
        staking.setOwnerDelegated(voter1, 1_200_000e18, 2_000_000e18);
        staking.setGlobalDelegated(2_000_000e18, 2_800_000e18);
        assertEq(stubStrategy.getVotingPower(voter1), 1_200_000e18);
        assertEq(stubStrategy.beforeVote(ProposalExtraData(0, 0)), 2_000_000e18);

        // (2) propose (fallback start), two votes and execution all succeed
        vm.prank(voter1);
        uint256 proposalId = governance.propose(_actions(_action(TARGET, "", 0)), "stuck epoch");
        assertEq(governance.getProposalById(proposalId).proposal.startBlockOrTime, block.timestamp);

        vm.warp(block.timestamp + 2);
        vm.prank(voter1);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Active));
        vm.prank(voter2);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));

        // (3) the snapshot denominator equals the frozen total: 1.2M of the 2M snapshot is
        // below two-thirds (stays Active); had the denominator followed the live next-epoch
        // total (2.8M), 1.5M would still be below 2/3 — identical behavior to the unstuck case
        assertEq(governance.proposalVotingPower(proposalId), 2_000_000e18);

        vm.warp(governance.getProposalById(proposalId).proposal.endBlockOrTime + 1);
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Succeeded));
        governance.execute(proposalId);
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Executed));
    }

    /// @notice Two consecutive votes while the proposal is Active snapshot the voting power
    ///     only once: the second vote cannot move the denominator.
    function test_StuckEpoch_SecondVote_DoesNotMoveSnapshot() public {
        StakingStub staking = new StakingStub();
        RigoblockGovernanceStrategy stubStrategy = new RigoblockGovernanceStrategy(address(staking), wormhole);
        StrategyHarness governance = new StrategyHarness();
        governance.setStrategy(address(stubStrategy));
        governance.setParams(1, 1);

        address voter1 = makeAddr("voter1");
        address voter2 = makeAddr("voter2");
        staking.setOwnerDelegated(voter1, 1_200_000e18, 1_200_000e18);
        staking.setOwnerDelegated(voter2, 100_000e18, 100_000e18);
        staking.setGlobalDelegated(2_000_000e18, 2_000_000e18);
        staking.setEpochEnd(block.timestamp - 1);
        staking.brickEndEpoch();

        vm.prank(voter1);
        uint256 proposalId = governance.propose(_actions(_action(TARGET, "", 0)), "snapshot once");
        vm.warp(block.timestamp + 2);

        vm.prank(voter1);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        assertEq(governance.proposalVotingPower(proposalId), 2_000_000e18);
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Active));

        // 1.2M + 0.1M = 1.3M still below two-thirds of the 2M snapshot: the second vote
        // cannot move the denominator, only the numerator
        vm.prank(voter2);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        assertEq(governance.proposalVotingPower(proposalId), 2_000_000e18);
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Active));
    }

    /// @notice A single vote that clears two-thirds of the frozen snapshot qualifies
    ///     identically to the unstuck case.
    function test_StuckEpoch_QualifiedAgainstFrozenSnapshot() public {
        StakingStub staking = new StakingStub();
        RigoblockGovernanceStrategy stubStrategy = new RigoblockGovernanceStrategy(address(staking), wormhole);
        StrategyHarness governance = new StrategyHarness();
        governance.setStrategy(address(stubStrategy));
        governance.setParams(1, 1);

        address voter1 = makeAddr("voter1");
        staking.setOwnerDelegated(voter1, 1_500_000e18, 1_500_000e18);
        staking.setGlobalDelegated(2_000_000e18, 2_000_000e18);
        staking.setEpochEnd(block.timestamp - 1);
        staking.brickEndEpoch();

        vm.prank(voter1);
        uint256 proposalId = governance.propose(_actions(_action(TARGET, "", 0)), "qualified stuck");
        vm.warp(block.timestamp + 2);

        vm.prank(voter1);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        // 3 * 1.5M > 2 * 2M: Qualified against the frozen snapshot
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Qualified));
    }

    function _stakingBackedGovernance(address whale) private returns (StrategyHarness) {
        // enough delegated stake to clear the drifted test's 400k quorum
        IStructs.StoredBalance memory balance = IStructs.StoredBalance({
            currentEpoch: 1,
            currentEpochBalance: uint96(500_000e18),
            nextEpochBalance: uint96(500_000e18)
        });
        IStructs.StoredBalance memory globalBalance = IStructs.StoredBalance({
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
            abi.encode(globalBalance)
        );

        StrategyHarness governance = new StrategyHarness();
        governance.setStrategy(address(strategy));
        governance.setParams(1, 1);
        return governance;
    }

    function _mockStaleClock() private {
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(IStaking.getCurrentEpochEarliestEndTimeInSeconds.selector),
            abi.encode(block.timestamp - 1)
        );
    }
}

/// @dev Exposes strategy storage, same pattern as the cross-chain tests.
contract StrategyHarness is RigoblockGovernance {
    // 2 is the Wormhole chain id of Ethereum, the governance hub
    constructor() RigoblockGovernance(2) {
        // updateThresholds validates the canonical name via the strategy; the harness skips
        // initialization, so the name is set here
        _name().value = "Rigoblock Governance";
    }
    function setStrategy(address strategy_) external {
        _paramsWrapper().governanceParameters.strategy = strategy_;
    }

    function setParams(uint256 proposalThreshold_, uint256 quorumThreshold_) external {
        _paramsWrapper().governanceParameters.proposalThreshold = proposalThreshold_;
        _paramsWrapper().governanceParameters.quorumThreshold = quorumThreshold_;
    }

    function proposalVotingPower(uint256 proposalId) external view returns (uint128) {
        return _proposalExtraData().proposalExtraDataById[proposalId].votingPower;
    }

    function proposalQuorum(uint256 proposalId) external view returns (uint128) {
        return _proposalExtraData().proposalExtraDataById[proposalId].quorum;
    }
}

/// @dev Minimal staking clock for epoch-roll tests: endEpoch advances the epoch end.
///      The return value is required by solc 0.8.37 even though callers ignore it.
contract StakingClockStub {
    uint256 public epochEnd;
    uint256 public endEpochCalls;

    constructor(uint256 epochEnd_) {
        epochEnd = epochEnd_;
    }

    function getCurrentEpochEarliestEndTimeInSeconds() external view returns (uint256) {
        return epochEnd;
    }

    function epochDurationInSeconds() external pure returns (uint256) {
        return 7 days;
    }

    function endEpoch() external virtual returns (uint256) {
        endEpochCalls++;
        epochEnd = block.timestamp + 7 days;
        return 0;
    }
}

/// @dev Staking stub with settable epoch balances and a brickable endEpoch, for stuck-epoch
///      consistency tests. Delegations land in the next-epoch balance, exactly like the real
///      staking contract, so a stuck epoch freezes currentEpochBalance reads.
contract StakingStub {
    uint256 public epochEnd;
    bool public endEpochBricked;
    uint256 internal _epochDuration = 7 days;
    mapping(address => IStructs.StoredBalance) internal _ownerDelegated;
    IStructs.StoredBalance internal _globalDelegated;

    function setEpochEnd(uint256 epochEnd_) external {
        epochEnd = epochEnd_;
    }

    function brickEndEpoch() external {
        endEpochBricked = true;
    }

    function setOwnerDelegated(address account, uint96 current, uint96 next) external {
        _ownerDelegated[account] = IStructs.StoredBalance({
            currentEpoch: 1,
            currentEpochBalance: current,
            nextEpochBalance: next
        });
    }

    function setGlobalDelegated(uint96 current, uint96 next) external {
        _globalDelegated = IStructs.StoredBalance({
            currentEpoch: 1,
            currentEpochBalance: current,
            nextEpochBalance: next
        });
    }

    function getCurrentEpochEarliestEndTimeInSeconds() external view returns (uint256) {
        return epochEnd;
    }

    function endEpoch() external returns (uint256) {
        require(!endEpochBricked, "endEpoch bricked");
        epochEnd = block.timestamp + _epochDuration;
        return 0;
    }

    function epochDurationInSeconds() external view returns (uint256) {
        return _epochDuration;
    }

    function getOwnerStakeByStatus(
        address account,
        IStructs.StakeStatus
    ) external view returns (IStructs.StoredBalance memory) {
        return _ownerDelegated[account];
    }

    function getGlobalStakeByStatus(IStructs.StakeStatus) external view returns (IStructs.StoredBalance memory) {
        return _globalDelegated;
    }
}
