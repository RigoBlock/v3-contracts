// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {IGovernanceState} from "../../contracts/governance/interfaces/governance/IGovernanceState.sol";
import {IGovernanceVoting} from "../../contracts/governance/interfaces/governance/IGovernanceVoting.sol";
import {ProposalStatus, ProposedAction} from "../../contracts/governance/types/GovernanceTypes.sol";
import {RigoblockGovernance} from "../../contracts/governance/RigoblockGovernance.sol";
import {RigoblockGovernanceStrategy} from "../../contracts/governance/strategies/RigoblockGovernanceStrategy.sol";
import {IStructs} from "../../contracts/staking/interfaces/IStructs.sol";

import {Test} from "forge-std/Test.sol";
import {ICoreBridge} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";

contract Counter {
    uint256 public value;

    function increment() external {
        value++;
    }
}

/// @title Staking stub with real next-epoch semantics
/// @notice Delegations apply to the next epoch and `endEpoch` promotes them, mirroring the
///     production staking scheduler: an epoch can only be rolled once its end time is reached.
///     Guards against future staking rule changes breaking governance voting-power accounting.
contract EpochStakingStub {
    error EpochNotEnded();

    uint256 public constant EPOCH_DURATION = 7 days;

    uint256 public epochEnd;
    uint256 public globalCurrent;
    uint256 public globalNext;
    mapping(address owner => uint256 balance) public ownerCurrent;
    mapping(address owner => uint256 balance) public ownerNext;
    address[] internal owners;

    constructor() {
        epochEnd = block.timestamp + EPOCH_DURATION;
    }

    function delegate(uint256 amount) external {
        if (ownerNext[msg.sender] == 0) owners.push(msg.sender);
        ownerNext[msg.sender] += amount;
        globalNext += amount;
    }

    function undelegate(uint256 amount) external {
        ownerNext[msg.sender] -= amount;
        globalNext -= amount;
    }

    function endEpoch() external returns (uint256) {
        require(block.timestamp >= epochEnd, EpochNotEnded());
        for (uint256 i = 0; i < owners.length; i++) {
            ownerCurrent[owners[i]] = ownerNext[owners[i]];
        }
        globalCurrent = globalNext;
        epochEnd = block.timestamp + EPOCH_DURATION;
        return 0;
    }

    function getCurrentEpochEarliestEndTimeInSeconds() external view returns (uint256) {
        return epochEnd;
    }

    function epochDurationInSeconds() external pure returns (uint256) {
        return EPOCH_DURATION;
    }

    function getGlobalStakeByStatus(IStructs.StakeStatus) external view returns (IStructs.StoredBalance memory) {
        return
            IStructs.StoredBalance({
                currentEpoch: 1,
                currentEpochBalance: uint96(globalCurrent),
                nextEpochBalance: uint96(globalNext)
            });
    }

    function getOwnerStakeByStatus(
        address owner,
        IStructs.StakeStatus
    ) external view returns (IStructs.StoredBalance memory) {
        return
            IStructs.StoredBalance({
                currentEpoch: 1,
                currentEpochBalance: uint96(ownerCurrent[owner]),
                nextEpochBalance: uint96(ownerNext[owner])
            });
    }
}

/// @title Harness exposing strategy storage, same pattern as the cross-chain tests.
contract VotingPowerHarness is RigoblockGovernance {
    // 2 is the Wormhole chain id of Ethereum, the governance hub
    constructor() RigoblockGovernance(2) {}
    function setStrategy(address strategy_) external {
        _paramsWrapper().governanceParameters.strategy = strategy_;
    }

    function setParams(uint256 proposalThreshold_, uint256 quorumThreshold_) external {
        _paramsWrapper().governanceParameters.proposalThreshold = proposalThreshold_;
        _paramsWrapper().governanceParameters.quorumThreshold = quorumThreshold_;
    }

    function proposalVotingPower(uint256 proposalId) external view returns (uint256) {
        return _proposalExtraData().proposalExtraDataById[proposalId].votingPower;
    }
}

/// @title Qualified-majority denominator semantics against a staking stub with real epoch rules.
/// @notice The total voting power is snapshotted on the first vote. The voting window is
///     strictly inside a single staking epoch (see RigoblockGovernanceStrategy.votingPeriod),
///     so no epoch roll is possible in-window and votes and denominator always share an epoch.
contract GovernanceVotingPowerTest is Test {
    uint256 internal constant WHALE_STAKE = 300_000e18;
    uint256 internal constant VOTER_STAKE = 400_000e18;

    EpochStakingStub internal staking;
    VotingPowerHarness internal governance;
    RigoblockGovernanceStrategy internal strategy;
    Counter internal counter;
    address internal whale = makeAddr("whale");
    address internal voter = makeAddr("voter");

    function setUp() public {
        staking = new EpochStakingStub();
        governance = new VotingPowerHarness();
        address wormhole = makeAddr("wormhole");
        // enough code for the constructor's code.length check and chainId() probe
        vm.etch(wormhole, hex"00");
        vm.mockCall(wormhole, abi.encodeCall(ICoreBridge.chainId, ()), abi.encode(uint16(2)));
        strategy = new RigoblockGovernanceStrategy(address(staking), wormhole);
        governance.setStrategy(address(strategy));
        governance.setParams(1, 1);
        counter = new Counter();
    }

    function _delegateBothAndRoll() internal {
        vm.prank(whale);
        staking.delegate(WHALE_STAKE);
        vm.prank(voter);
        staking.delegate(VOTER_STAKE);
        vm.warp(staking.epochEnd());
        staking.endEpoch();
    }

    function _incrementAction() private view returns (ProposedAction[] memory actions) {
        actions = new ProposedAction[](1);
        actions[0] = ProposedAction({target: address(counter), data: abi.encodeCall(Counter.increment, ()), value: 0});
    }

    /// @notice A delegation made after proposal creation but before voting starts counts fully:
    ///     in the numerator (voting power) and in the denominator (the first-vote snapshot).
    ///     With the snapshotted 700k the 400k vote stays below two-thirds, so the proposal
    ///     reports Active; a proposal-creation snapshot of 300k would have reported Qualified.
    function test_VotingPower_PostProposalDelegation_CountsInNumeratorAndDenominator() public {
        vm.prank(whale);
        staking.delegate(WHALE_STAKE);
        vm.warp(staking.epochEnd());
        staking.endEpoch();

        vm.prank(whale);
        uint256 proposalId = governance.propose(_incrementAction(), "post-proposal delegation");
        uint256 start = IGovernanceState(address(governance)).getProposalById(proposalId).proposal.startBlockOrTime;

        vm.prank(voter);
        staking.delegate(VOTER_STAKE);
        vm.warp(start);
        staking.endEpoch();
        vm.warp(start + 1);

        vm.prank(voter);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));

        assertEq(governance.proposalVotingPower(proposalId), WHALE_STAKE + VOTER_STAKE);
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Active));
    }

    /// @notice Regression for the shrinkable-denominator attack: after the first vote stores
    ///     the snapshot, the supporter undelegates and the epoch rolls, shrinking the live
    ///     delegated supply far below the point where the recorded votes would clear two-thirds
    ///     of it. The frozen snapshot keeps the proposal Active at the deadline; past it, the
    ///     vote counts decide and the proposal succeeds and executes honestly.
    function test_VotingPower_SnapshotFrozenAfterFirstVote_ShrinkDoesNotQualify() public {
        _delegateBothAndRoll();

        vm.prank(whale);
        uint256 proposalId = governance.propose(_incrementAction(), "frozen snapshot");
        uint256 start = IGovernanceState(address(governance)).getProposalById(proposalId).proposal.startBlockOrTime;

        vm.warp(start);
        staking.endEpoch();
        vm.warp(start + 1);
        vm.prank(voter);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Active));

        vm.prank(voter);
        staking.undelegate(VOTER_STAKE);

        // 400k of the frozen 700k snapshot is below two-thirds, even though the live supply
        // (300k) would qualify it; the voting window is strictly inside the epoch (7 days - 1),
        // so at its end the proposal is still Active
        vm.warp(start + 7 days - 1);
        assertEq(governance.proposalVotingPower(proposalId), WHALE_STAKE + VOTER_STAKE);
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Active));

        // after the deadline the honest vote counts decide: the proposal succeeds and executes
        vm.warp(start + 7 days + 1);
        staking.endEpoch();
        assertEq(staking.globalCurrent(), WHALE_STAKE);
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Succeeded));
        governance.execute(proposalId);
        assertEq(counter.value(), 1);
    }

    /// @notice The stub enforces single-epoch windows: a finished epoch cannot be rolled early,
    ///     so votes and the snapshot can never straddle a rollover mid-proposal.
    function test_VotingPower_MidWindowEpochRoll_Reverts() public {
        _delegateBothAndRoll();

        vm.prank(whale);
        uint256 proposalId = governance.propose(_incrementAction(), "no mid-window roll");
        uint256 start = IGovernanceState(address(governance)).getProposalById(proposalId).proposal.startBlockOrTime;

        vm.warp(start - 1);
        vm.expectRevert(EpochStakingStub.EpochNotEnded.selector);
        staking.endEpoch();
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Pending));
    }

    /// @notice Proposing in a finished epoch rolls it forward first: the proposal starts at the
    ///     boundary of the new epoch, never inside a dead one.
    function test_VotingPower_StaleEpochAtPropose_RollsForward() public {
        vm.prank(whale);
        staking.delegate(WHALE_STAKE);
        vm.warp(staking.epochEnd());
        staking.endEpoch();
        vm.warp(staking.epochEnd() + 1);

        vm.prank(whale);
        uint256 proposalId = governance.propose(_incrementAction(), "stale epoch");
        uint256 start = IGovernanceState(address(governance)).getProposalById(proposalId).proposal.startBlockOrTime;

        assertEq(staking.globalCurrent(), WHALE_STAKE);
        assertEq(start, staking.epochEnd());
        assertEq(start, block.timestamp + 7 days);
    }

    /// @notice Regression for the mid-window electorate-growth attack: an attacker delegating
    ///     mid-proposal can roll the epoch during the window (the roll is permissionless) and
    ///     vote with the promoted balance, but the first-vote snapshot is frozen, so the new
    ///     votes land in the numerator only and must still clear two-thirds of the snapshot
    ///     to qualify.
    function test_VotingPower_MidWindowRoll_GrowElectorate_CannotQualifyAgainstFrozenSnapshot() public {
        address attacker = makeAddr("attacker");
        uint256 whaleStake = 4_000_000e18;
        uint256 scapeStake = 100;
        uint256 midWindowDelegation = 2_000_000e18;

        vm.prank(whale);
        staking.delegate(whaleStake);
        vm.prank(voter);
        staking.delegate(scapeStake);
        vm.warp(staking.epochEnd());
        staking.endEpoch();

        // proposing with a stale epoch rolls it: the window starts at the new epoch's boundary
        vm.warp(staking.epochEnd() + 1);
        vm.prank(whale);
        uint256 proposalId = governance.propose(_incrementAction(), "mid-window roll");
        uint256 start = IGovernanceState(address(governance)).getProposalById(proposalId).proposal.startBlockOrTime;

        // the attacker delegates a whale amount mid-proposal (effective next epoch)
        vm.prank(attacker);
        staking.delegate(midWindowDelegation);

        // the first vote snapshots the pre-attack electorate: the attacker is not in it
        vm.warp(start + 1);
        vm.prank(voter);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        assertEq(governance.proposalVotingPower(proposalId), whaleStake + scapeStake);

        // the epoch roll is permissionless and succeeds inside the window, promoting the
        // attacker's delegation into the current epoch
        staking.endEpoch();
        assertEq(staking.globalCurrent(), whaleStake + scapeStake + midWindowDelegation);

        // the attacker votes with the promoted balance, but 2M is below two-thirds of the
        // frozen 4M snapshot: the proposal stays Active
        vm.prank(attacker);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Active));

        // at the deadline the honest vote counts decide: 2M against 100 succeeds and executes
        vm.warp(start + 7 days);
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Succeeded));
        governance.execute(proposalId);
        assertEq(counter.value(), 1);
    }
}
