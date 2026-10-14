// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {IGovernanceState} from "../../contracts/governance/interfaces/governance/IGovernanceState.sol";
import {IGovernanceVoting} from "../../contracts/governance/interfaces/governance/IGovernanceVoting.sol";
import {ProposalStatus, ProposedAction, ProposalExtraData} from "../../contracts/governance/types/GovernanceTypes.sol";
import {RigoblockGovernance} from "../../contracts/governance/RigoblockGovernance.sol";
import {RigoblockGovernanceStrategy} from "../../contracts/governance/strategies/RigoblockGovernanceStrategy.sol";
import {IStructs} from "../../contracts/staking/interfaces/IStructs.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";

import {Test} from "forge-std/Test.sol";
import {ICoreBridge} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";

import {ReentrancyGuardTransient} from "../../contracts/protocol/libraries/ReentrancyGuardTransient.sol";

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
    error EpochBricked();

    uint256 public constant EPOCH_DURATION = 7 days;

    uint256 public epochEnd;
    uint256 public globalCurrent;
    uint256 public globalNext;
    bool public bricked;
    mapping(address owner => uint256 balance) public ownerCurrent;
    mapping(address owner => uint256 balance) public ownerNext;
    address[] internal owners;

    constructor() {
        epochEnd = block.timestamp + EPOCH_DURATION;
    }

    function brick() external {
        bricked = true;
    }

    function unbrick() external {
        bricked = false;
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
        require(!bricked, EpochBricked());
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

/// @dev Strategy that counts `beforeVote` invocations, to prove the hook runs before every vote.
///      Delegates to a separately deployed base strategy to avoid self-dispatch recursion.
contract CountingStrategy is RigoblockGovernanceStrategy {
    uint256 public beforeVoteCalls;
    RigoblockGovernanceStrategy internal immutable _base;

    constructor(
        address stakingProxy,
        address coreBridge,
        RigoblockGovernanceStrategy base_
    ) RigoblockGovernanceStrategy(stakingProxy, coreBridge) {
        _base = base_;
    }

    function beforeVote(ProposalExtraData calldata extraData) external override returns (uint256 totalVotingPower) {
        beforeVoteCalls++;
        return _base.beforeVote(extraData);
    }
}

/// @dev Strategy that reenters a guarded governance entry point from a hook when armed.
///      A flawed upgradeable strategy must not become a reentrancy lever. Delegates to a
///      separately deployed base strategy to avoid self-dispatch recursion.
contract ReenteringStrategy is RigoblockGovernanceStrategy {
    enum Attack {
        None,
        Propose,
        Vote,
        Execute
    }

    Attack internal _attack;
    address internal immutable _governance;
    RigoblockGovernanceStrategy internal immutable _base;
    uint256 internal _proposalId;

    constructor(
        address stakingProxy,
        address coreBridge,
        address governance_,
        RigoblockGovernanceStrategy base_
    ) RigoblockGovernanceStrategy(stakingProxy, coreBridge) {
        _governance = governance_;
        _base = base_;
    }

    function arm(Attack attack_, uint256 proposalId) external {
        _attack = attack_;
        _proposalId = proposalId;
    }

    function _attackIfArmed() internal {
        // each nested call must revert at the transient guard before touching state
        if (_attack == Attack.Propose) {
            RigoblockGovernance(payable(_governance)).propose(new ProposedAction[](1), "reentrancy");
        } else if (_attack == Attack.Vote) {
            RigoblockGovernance(payable(_governance)).castVote(_proposalId, uint8(IGovernanceVoting.VoteType.For));
        } else if (_attack == Attack.Execute) {
            RigoblockGovernance(payable(_governance)).execute(_proposalId);
        }
    }

    function beforePropose(
        ProposedAction[] calldata actions
    ) external override returns (ProposedAction[] memory, uint256, uint256) {
        _attackIfArmed();
        return _base.beforePropose(actions);
    }

    function beforeVote(ProposalExtraData calldata extraData) external override returns (uint256 totalVotingPower) {
        _attackIfArmed();
        return _base.beforeVote(extraData);
    }

    function beforeExecute(ProposedAction[] calldata actions) external view override returns (ProposedAction[] memory) {
        return _base.beforeExecute(actions);
    }
}

/// @title Qualified-majority denominator semantics against a staking stub with real epoch rules.
/// @notice The total voting power is snapshotted on the first vote, and the first vote rolls a
///     finished epoch best-effort first, so the snapshot and all votes share one epoch. The
///     residual frozen-snapshot case is the stuck-at-first-vote scenario (see the known
///     limitation in docs/governance/STRATEGY.md).
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

    /// @notice The stub enforces epoch timing: a finished epoch cannot be rolled early, so a
    ///     roll attempted before the window opens reverts. Inside the window the roll succeeds
    ///     (see the mid-window tests below).
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

    /// @notice The first vote rolls a finished epoch best-effort: the voting window opens
    ///     exactly when the epoch becomes rollable, so without the roll the snapshot would
    ///     freeze the pre-roll electorate while a lazy mid-window roll promotes new delegations
    ///     under later votes. The roll lands inside the first vote and the snapshot is the NEW
    ///     epoch's total.
    function test_VotingPower_FirstVoteRolls_UnrolledEpoch_SnapshotInNewEpoch() public {
        address lateDelegate = makeAddr("lateDelegate");
        uint256 lateStake = 2_000_000e18;

        _delegateBothAndRoll();

        // propose while the epoch is live: no roll at propose, the window starts at its end
        vm.warp(staking.epochEnd() - 2 days);
        vm.prank(whale);
        uint256 proposalId = governance.propose(_incrementAction(), "first vote rolls");
        uint256 start = IGovernanceState(address(governance)).getProposalById(proposalId).proposal.startBlockOrTime;
        assertEq(start, staking.epochEnd());

        // a delegation lands mid-window, effective next epoch; nobody rolls the finished epoch
        vm.warp(start + 1);
        vm.prank(lateDelegate);
        staking.delegate(lateStake);
        assertEq(staking.globalCurrent(), WHALE_STAKE + VOTER_STAKE);

        // the first vote carries the roll: the epoch advances and the snapshot counts the
        // mid-window delegation, i.e. it is the new epoch's total, not the frozen old one
        vm.prank(voter);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        assertEq(staking.epochEnd(), block.timestamp + 7 days);
        assertEq(staking.globalCurrent(), WHALE_STAKE + VOTER_STAKE + lateStake);
        assertEq(governance.proposalVotingPower(proposalId), WHALE_STAKE + VOTER_STAKE + lateStake);
    }

    /// @notice A mid-window roll that lands BEFORE the first vote is absorbed: the first vote
    ///     finds a live epoch (its internal roll is skipped), the snapshot is the post-roll
    ///     electorate, and later votes count against a live denominator — no frozen snapshot,
    ///     no double appearance.
    function test_VotingPower_PreFirstVoteRoll_Absorbed_SnapshotInPostRollEpoch() public {
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
        uint256 proposalId = governance.propose(_incrementAction(), "pre-first-vote roll");
        uint256 start = IGovernanceState(address(governance)).getProposalById(proposalId).proposal.startBlockOrTime;

        // the attacker delegates a whale amount mid-window (effective next epoch), then anyone
        // rolls the finished epoch before the first vote and promotes it
        vm.warp(start + 1);
        vm.prank(attacker);
        staking.delegate(midWindowDelegation);
        staking.endEpoch();
        assertEq(staking.globalCurrent(), whaleStake + scapeStake + midWindowDelegation);

        // the first vote finds a live epoch and snapshots the post-roll electorate
        vm.prank(voter);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        assertEq(governance.proposalVotingPower(proposalId), whaleStake + scapeStake + midWindowDelegation);

        // the attacker votes with the promoted balance against a LIVE snapshot: 2M against the
        // 6M total is consistent accounting, and the proposal stays Active
        vm.prank(attacker);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        IGovernanceState.Proposal memory proposal = governance.getProposalById(proposalId).proposal;
        assertEq(proposal.votesFor, scapeStake + midWindowDelegation);
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Active));
    }

    /// @notice The residual documented limitation: the epoch is STUCK at the first vote
    ///     (endEpoch reverts and the strategy's try/catch swallows it), then un-sticks
    ///     mid-window. The snapshot stays frozen while post-roll votes carry new-epoch power,
    ///     and an account-scoped delegation move lets the same stake appear twice in votesFor.
    function test_VotingPower_StuckAtFirstVote_UnsticksMidWindow_SameStakeCountedTwice() public {
        address attacker = makeAddr("attacker");
        uint256 whaleStake = 4_000_000e18;
        uint256 scapeStake = 3_000_000e18;

        vm.prank(whale);
        staking.delegate(whaleStake);
        vm.prank(voter);
        staking.delegate(scapeStake);
        vm.warp(staking.epochEnd());
        staking.endEpoch();

        // propose while the epoch is live: the window starts at its end
        vm.warp(staking.epochEnd() - 2 days);
        vm.prank(whale);
        uint256 proposalId = governance.propose(_incrementAction(), "stuck at first vote");
        uint256 start = IGovernanceState(address(governance)).getProposalById(proposalId).proposal.startBlockOrTime;

        // the epoch goes stale and bricks: the first vote's internal roll is swallowed and the
        // snapshot freezes at the pre-move electorate
        vm.warp(start + 1);
        staking.brick();
        vm.prank(whale);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        assertEq(staking.epochEnd(), start);
        assertEq(governance.proposalVotingPower(proposalId), whaleStake + scapeStake);

        // the delegation moves to the attacker, effective next epoch; the epoch then un-sticks
        // and a DIRECT mid-window endEpoch promotes it — governance votes no longer roll the
        // epoch once the snapshot exists
        vm.prank(whale);
        staking.undelegate(whaleStake);
        vm.prank(attacker);
        staking.delegate(whaleStake);
        staking.unbrick();
        staking.endEpoch();
        assertEq(staking.globalCurrent(), whaleStake + scapeStake);

        // the attacker votes with the moved stake: same stake, second appearance in votesFor,
        // and 8M now clears two-thirds of the frozen 7M snapshot
        vm.prank(attacker);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));

        IGovernanceState.Proposal memory proposal = governance.getProposalById(proposalId).proposal;
        assertEq(proposal.votesFor, 2 * whaleStake);
        assertEq(governance.proposalVotingPower(proposalId), whaleStake + scapeStake);
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(ProposalStatus.Qualified));
    }

    /// @dev Deploys a mocked wormhole, staking stub and harness; each caller constructs its own
    ///     strategy against the local staking and wires it via setStrategy.
    function _deployWired()
        internal
        returns (address localWormhole, EpochStakingStub localStaking, VotingPowerHarness localGov)
    {
        localWormhole = makeAddr("localWormhole");
        vm.etch(localWormhole, hex"00");
        vm.mockCall(localWormhole, abi.encodeCall(ICoreBridge.chainId, ()), abi.encode(uint16(2)));
        localStaking = new EpochStakingStub();
        localGov = new VotingPowerHarness();
        localGov.setParams(1, 1);

        vm.prank(whale);
        localStaking.delegate(WHALE_STAKE);
        vm.prank(voter);
        localStaking.delegate(VOTER_STAKE);
        vm.warp(localStaking.epochEnd());
        localStaking.endEpoch();
    }

    /// @notice The beforeVote hook runs before EVERY vote; the governance stores its return as
    ///     the proposal snapshot on the first vote only, and the single-snapshot guarantee holds.
    function test_BeforeVoteHook_CalledPerVote_SnapshotStoredOnce() public {
        (address localWormhole, EpochStakingStub localStaking, VotingPowerHarness localGov) = _deployWired();
        RigoblockGovernanceStrategy base = new RigoblockGovernanceStrategy(address(localStaking), localWormhole);
        CountingStrategy counting = new CountingStrategy(address(localStaking), localWormhole, base);
        localGov.setStrategy(address(counting));

        vm.prank(whale);
        uint256 proposalId = localGov.propose(_incrementAction(), "hook per vote");
        uint256 start = IGovernanceState(address(localGov)).getProposalById(proposalId).proposal.startBlockOrTime;

        vm.warp(start + 1);
        vm.prank(voter);
        localGov.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        assertEq(counting.beforeVoteCalls(), 1);
        assertEq(localGov.proposalVotingPower(proposalId), WHALE_STAKE + VOTER_STAKE);

        // the hook runs again before the second vote, but the stored snapshot does not move
        vm.prank(whale);
        localGov.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        assertEq(counting.beforeVoteCalls(), 2);
        assertEq(localGov.proposalVotingPower(proposalId), WHALE_STAKE + VOTER_STAKE);
    }

    /// @notice Once the snapshot exists, the hook receives it and skips every staking call:
    ///     with the hook's three staking entry points revert-mocked, the second vote still
    ///     succeeds — any post-snapshot staking interaction would revert the vote.
    function test_BeforeVoteHook_NoStakingCalls_AfterSnapshot() public {
        (address localWormhole, EpochStakingStub localStaking, VotingPowerHarness localGov) = _deployWired();
        RigoblockGovernanceStrategy base = new RigoblockGovernanceStrategy(address(localStaking), localWormhole);
        CountingStrategy counting = new CountingStrategy(address(localStaking), localWormhole, base);
        localGov.setStrategy(address(counting));

        vm.prank(whale);
        uint256 proposalId = localGov.propose(_incrementAction(), "no staking calls post snapshot");
        uint256 start = IGovernanceState(address(localGov)).getProposalById(proposalId).proposal.startBlockOrTime;

        vm.warp(start + 1);
        vm.prank(voter);
        localGov.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        assertEq(localGov.proposalVotingPower(proposalId), WHALE_STAKE + VOTER_STAKE);

        // the hook path's staking entry points: any post-snapshot call to them reverts the vote
        bytes memory noReason = "";
        vm.mockCallRevert(
            address(localStaking),
            abi.encodeCall(IStaking.getCurrentEpochEarliestEndTimeInSeconds, ()),
            noReason
        );
        vm.mockCallRevert(address(localStaking), abi.encodeCall(IStaking.endEpoch, ()), noReason);
        vm.mockCallRevert(
            address(localStaking),
            abi.encodeCall(IStaking.getGlobalStakeByStatus, (IStructs.StakeStatus.DELEGATED)),
            noReason
        );

        vm.prank(whale);
        localGov.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        assertEq(counting.beforeVoteCalls(), 2);
        assertEq(localGov.proposalVotingPower(proposalId), WHALE_STAKE + VOTER_STAKE);
    }

    /// @notice A flawed upgradeable strategy cannot reenter the governance through any hook:
    ///     the transient guard reverts the nested call before it touches state, and the outer
    ///     transaction unwinds.
    function test_ReentrancyGuard_BlocksReenteringStrategy() public {
        (address localWormhole, EpochStakingStub localStaking, VotingPowerHarness localGov) = _deployWired();
        RigoblockGovernanceStrategy base = new RigoblockGovernanceStrategy(address(localStaking), localWormhole);
        ReenteringStrategy attack = new ReenteringStrategy(
            address(localStaking),
            localWormhole,
            address(localGov),
            base
        );
        localGov.setStrategy(address(attack));

        // vote reentrancy from beforeVote
        vm.prank(whale);
        uint256 proposalId = localGov.propose(_incrementAction(), "reentrancy guard");
        uint256 start = IGovernanceState(address(localGov)).getProposalById(proposalId).proposal.startBlockOrTime;
        vm.warp(start + 1);

        attack.arm(ReenteringStrategy.Attack.Vote, proposalId);
        vm.prank(voter);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        localGov.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));

        // the proposal is untouched and the voter can vote once the strategy is disarmed
        attack.arm(ReenteringStrategy.Attack.None, 0);
        vm.prank(voter);
        localGov.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        assertEq(localGov.proposalVotingPower(proposalId), WHALE_STAKE + VOTER_STAKE);

        // propose reentrancy from beforePropose
        attack.arm(ReenteringStrategy.Attack.Propose, 0);
        vm.prank(whale);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        localGov.propose(_incrementAction(), "reentrant propose");
        assertEq(localGov.proposalCount(), 1);

        // finish the proposal honestly: state Succeeded, never executed
        attack.arm(ReenteringStrategy.Attack.None, 0);
        vm.prank(whale);
        localGov.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        uint256 end = IGovernanceState(address(localGov)).getProposalById(proposalId).proposal.endBlockOrTime;
        vm.warp(end + 1);
        assertEq(uint256(localGov.getProposalState(proposalId)), uint256(ProposalStatus.Succeeded));

        // execute reentrancy: the armed attack fires from beforePropose during a new proposal,
        // reentering execute on the succeeded proposal; the nested call reverts at the guard
        attack.arm(ReenteringStrategy.Attack.Execute, proposalId);
        vm.prank(whale);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        localGov.propose(_incrementAction(), "reentrant execute");
        assertEq(localGov.proposalCount(), 1);
        assertEq(uint256(localGov.getProposalState(proposalId)), uint256(ProposalStatus.Succeeded));
    }
}
