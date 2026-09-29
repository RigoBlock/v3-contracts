// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {CrossChainPayload} from "../../contracts/governance/types/GovernanceTypes.sol";
import {IGovernanceCrosschain} from "../../contracts/governance/interfaces/governance/IGovernanceCrosschain.sol";
import {IGovernanceState} from "../../contracts/governance/interfaces/governance/IGovernanceState.sol";
import {IGovernanceUpgrade} from "../../contracts/governance/interfaces/governance/IGovernanceUpgrade.sol";
import {IGovernanceVoting} from "../../contracts/governance/interfaces/governance/IGovernanceVoting.sol";
import {RigoblockGovernance} from "../../contracts/governance/RigoblockGovernance.sol";
import {RigoblockGovernanceStrategy} from "../../contracts/governance/strategies/RigoblockGovernanceStrategy.sol";

import {Test} from "forge-std/Test.sol";
import {ICoreBridge, CoreBridgeVM, GuardianSignature} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";
import {CHAIN_ID_ETHEREUM, CHAIN_ID_HYPER_EVM} from "wormhole-solidity-sdk/src/constants/Chains.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {IERC20} from "../../contracts/tokens/ERC20/IERC20.sol";
import {IStructs} from "../../contracts/staking/interfaces/IStructs.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {IStorage} from "../../contracts/staking/interfaces/IStorage.sol";

contract Counter {
    uint256 public value;

    function increment() external {
        value++;
    }

    function setValue(uint256 newValue) external {
        value = newValue;
    }
}

contract FlakyTarget {
    error TargetRevert();

    bool public shouldRevert;

    function setShouldRevert(bool newShouldRevert) external {
        shouldRevert = newShouldRevert;
    }

    function run() external view {
        require(!shouldRevert, TargetRevert());
    }
}

/// @title Governance crosschain harness
/// @notice Deploys the governance implementation standalone and exposes strategy storage,
///     mirroring the MigrationHarness pattern used by GovernanceMigration.t.sol.
contract CrosschainHarness is RigoblockGovernance {
    constructor() RigoblockGovernance() {}

    function setStrategy(address strategy_) external {
        _paramsWrapper().governanceParameters.strategy = strategy_;
    }

    function setParams(uint256 proposalThreshold_, uint256 quorumThreshold_) external {
        _paramsWrapper().governanceParameters.proposalThreshold = proposalThreshold_;
        _paramsWrapper().governanceParameters.quorumThreshold = quorumThreshold_;
    }

    function implementation() external view returns (address) {
        return _implementation().value;
    }
}

/// @title Tests for the cross-chain receiver implemented inside the governance.
/// @notice Wormhole's parseAndVerifyVM is mocked: these tests exercise the governance's own
///     state machine (ordering, replay protection, gaps, expiry), not VAA cryptography.
contract GovernanceCrosschainTest is Test {
    uint16 internal constant EMITTER_CHAIN = CHAIN_ID_ETHEREUM;
    uint16 internal constant TARGET_CHAIN = CHAIN_ID_HYPER_EVM;
    address internal constant STAKING = address(0x1111);
    address internal constant WORMHOLE = Constants.WORMHOLE_HYPEREVM;
    uint256 internal constant DELEGATED_BALANCE = 1_000_000e18;

    CrosschainHarness internal governance;
    RigoblockGovernanceStrategy internal strategy;
    Counter internal counter;
    address internal whale = makeAddr("whale");

    function setUp() public {
        strategy = new RigoblockGovernanceStrategy(STAKING, WORMHOLE, TARGET_CHAIN);
        governance = new CrosschainHarness();
        governance.setStrategy(address(strategy));
        counter = new Counter();
    }

    function _encodePayload(IGovernanceVoting.ProposedAction memory action) private pure returns (bytes memory) {
        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](1);
        actions[0] = action;
        return _encodePayload(actions, 1);
    }

    function _encodePayload(
        IGovernanceVoting.ProposedAction[] memory actions,
        uint256 proposalId
    ) private pure returns (bytes memory) {
        return
            abi.encode(
                CrossChainPayload({targetWormholeChainId: TARGET_CHAIN, proposalId: proposalId, actions: actions})
            );
    }

    function _buildVaa(bytes memory payload, uint64 sequence) private view returns (CoreBridgeVM memory) {
        return _buildVaa(payload, sequence, uint32(block.timestamp));
    }

    function _buildVaa(
        bytes memory payload,
        uint64 sequence,
        uint32 timestamp
    ) private view returns (CoreBridgeVM memory) {
        return
            CoreBridgeVM({
                version: 1,
                timestamp: timestamp,
                nonce: 0,
                emitterChainId: EMITTER_CHAIN,
                emitterAddress: bytes32(uint256(uint160(address(governance)))),
                sequence: sequence,
                consistencyLevel: 1,
                payload: payload,
                guardianSetIndex: 0,
                signatures: new GuardianSignature[](0),
                hash: keccak256(abi.encode(payload, sequence))
            });
    }

    function _mockParseAndVerify(CoreBridgeVM memory vaa) private {
        vm.mockCall(WORMHOLE, abi.encodeWithSelector(ICoreBridge.parseAndVerifyVM.selector), abi.encode(vaa, true, ""));
    }

    function _buildIncrementAction() private view returns (IGovernanceVoting.ProposedAction memory) {
        return
            IGovernanceVoting.ProposedAction({
                target: address(counter),
                data: abi.encodeCall(Counter.increment, ()),
                value: 0
            });
    }

    function _wrap(
        IGovernanceVoting.ProposedAction memory action
    ) private pure returns (IGovernanceVoting.ProposedAction[] memory) {
        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](1);
        actions[0] = action;
        return actions;
    }

    function test_ReceiveMessage_HappyPath() public {
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);
        _mockParseAndVerify(_buildVaa(payload, 0));

        governance.receiveMessage("");
        assertEq(counter.value(), 1);
        assertEq(governance.nextMinimumSequence(), 1);
    }

    function test_ReceiveMessage_NotConfigured_Reverts() public {
        CrosschainHarness unconfigured = new CrosschainHarness();

        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0));

        vm.expectRevert(IGovernanceCrosschain.GovReceiverNotConfigured.selector);
        unconfigured.receiveMessage("");
    }

    function test_ReceiveMessage_WormholeDisabledInStrategy_Reverts() public {
        CrosschainHarness otherChain = new CrosschainHarness();
        // a strategy with a zero Wormhole address (e.g. a chain that is not a receiver)
        otherChain.setStrategy(address(new RigoblockGovernanceStrategy(STAKING, address(0), TARGET_CHAIN)));

        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0));

        vm.expectRevert(IGovernanceCrosschain.GovReceiverNotConfigured.selector);
        otherChain.receiveMessage("");
    }

    function test_ReceiveMessage_UnknownEmitter_Reverts() public {
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);
        CoreBridgeVM memory vaa = _buildVaa(payload, 0);
        vaa.emitterAddress = bytes32(uint256(1));
        _mockParseAndVerify(vaa);

        vm.expectRevert(IGovernanceCrosschain.GovReceiverUnknownEmitter.selector);
        governance.receiveMessage("");
    }

    function test_ReceiveMessage_UnknownEmitterChain_Reverts() public {
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);
        CoreBridgeVM memory vaa = _buildVaa(payload, 0);
        vaa.emitterChainId = EMITTER_CHAIN + 1;
        _mockParseAndVerify(vaa);

        vm.expectRevert(IGovernanceCrosschain.GovReceiverUnknownEmitter.selector);
        governance.receiveMessage("");
    }

    function test_ReceiveMessage_WrongChain_Reverts() public {
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = abi.encode(
            CrossChainPayload({targetWormholeChainId: 9999, proposalId: 1, actions: _wrap(action)})
        );
        _mockParseAndVerify(_buildVaa(payload, 0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceCrosschain.GovReceiverWrongChain.selector,
                uint16(9999),
                uint16(TARGET_CHAIN)
            )
        );
        governance.receiveMessage("");
    }

    function test_ReceiveMessage_LocalEmitter_Reverts() public {
        // a chain whose Wormhole chain id equals the emitter's (i.e. the sender chain itself)
        governance.setStrategy(address(new RigoblockGovernanceStrategy(STAKING, WORMHOLE, EMITTER_CHAIN)));

        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);
        _mockParseAndVerify(_buildVaa(payload, 0));

        vm.expectRevert(abi.encodeWithSelector(IGovernanceCrosschain.GovReceiverLocalEmitter.selector, EMITTER_CHAIN));
        governance.receiveMessage("");
    }

    function test_ReceiveMessage_InvalidVaa_Reverts() public {
        vm.mockCall(
            WORMHOLE,
            abi.encodeWithSelector(ICoreBridge.parseAndVerifyVM.selector),
            abi.encode(_buildVaa("", 0), false, "invalid signature")
        );

        vm.expectRevert(
            abi.encodeWithSelector(IGovernanceCrosschain.GovReceiverInvalidVaa.selector, "invalid signature")
        );
        governance.receiveMessage("");
    }

    function test_ReceiveMessage_MalformedPayload_Reverts() public {
        CoreBridgeVM memory vaa = _buildVaa(hex"1234", 0);
        _mockParseAndVerify(vaa);

        vm.expectRevert();
        governance.receiveMessage("");

        // the nonce did not advance, so later valid messages are not bricked
        assertEq(governance.nextMinimumSequence(), 0);
    }

    /// @notice A re-delivered VAA is rejected by the monotonic sequence check.
    function test_ReceiveMessage_ReplayedVaa_Reverts() public {
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);
        _mockParseAndVerify(_buildVaa(payload, 0));

        governance.receiveMessage("");
        assertEq(counter.value(), 1);

        vm.expectRevert(
            abi.encodeWithSelector(IGovernanceCrosschain.GovReceiverInvalidSequence.selector, uint64(0), uint64(1))
        );
        governance.receiveMessage("");
        assertEq(counter.value(), 1);
        assertEq(governance.nextMinimumSequence(), 1);
    }

    /// @notice A governance-approved re-send executes as a new message: the sender chain
    ///     published the action again, so it carries a new sequence and is not a replay.
    function test_ReceiveMessage_ResentAction_ExecutesAsNewMessage() public {
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);

        _mockParseAndVerify(_buildVaa(payload, 0));
        governance.receiveMessage("");
        assertEq(counter.value(), 1);
        assertEq(governance.nextMinimumSequence(), 1);

        // the sender chain re-publishes the same action (new sequence, new VAA)
        _mockParseAndVerify(_buildVaa(payload, 1));
        governance.receiveMessage("");
        assertEq(counter.value(), 2);
        assertEq(governance.nextMinimumSequence(), 2);
    }

    /// @notice Sequences need not be consecutive (audited Uniswap receiver model): a message
    ///     with a higher sequence delivers even if earlier sequences never executed, and a
    ///     later message with a lower sequence is rejected.
    function test_ReceiveMessage_GapAllowed_HigherSequenceSkipsMissing() public {
        IGovernanceVoting.ProposedAction memory action1 = _buildIncrementAction();
        IGovernanceVoting.ProposedAction memory action2 = IGovernanceVoting.ProposedAction({
            target: address(counter),
            data: abi.encodeCall(Counter.setValue, (42)),
            value: 0
        });

        // sequence 1 delivers first: sequence 0 never executed, the gap is allowed
        _mockParseAndVerify(_buildVaa(_encodePayload(action2), 1));
        governance.receiveMessage("");
        assertEq(counter.value(), 42);
        assertEq(governance.nextMinimumSequence(), 2);

        // the stale sequence 0 message is now permanently rejected
        _mockParseAndVerify(_buildVaa(_encodePayload(action1), 0));
        vm.expectRevert(
            abi.encodeWithSelector(IGovernanceCrosschain.GovReceiverInvalidSequence.selector, uint64(0), uint64(2))
        );
        governance.receiveMessage("");
        assertEq(governance.nextMinimumSequence(), 2);
    }

    /// @notice A reverting action reverts the whole message with the target's return data and
    ///     is not consumed: the sequence does not advance, so the same VAA can be re-delivered
    ///     (e.g. after the failure condition is fixed) or skipped by a later sequence.
    function test_ReceiveMessage_ExecutionFailure_RevertsAndStaysRedeliverable() public {
        FlakyTarget flaky = new FlakyTarget();
        flaky.setShouldRevert(true);
        IGovernanceVoting.ProposedAction memory action = IGovernanceVoting.ProposedAction({
            target: address(flaky),
            data: abi.encodeCall(FlakyTarget.run, ()),
            value: 0
        });
        bytes memory payload = _encodePayload(action);
        _mockParseAndVerify(_buildVaa(payload, 0));

        vm.expectRevert(abi.encodeWithSelector(FlakyTarget.TargetRevert.selector));
        governance.receiveMessage("");

        // not consumed: same VAA re-delivers, and succeeds once the target stops reverting
        assertEq(governance.nextMinimumSequence(), 0);
        flaky.setShouldRevert(false);
        governance.receiveMessage("");
        assertEq(governance.nextMinimumSequence(), 1);
    }

    /// @notice The message after a failed one still executes: the failed sequence stays
    ///     unconsumed but never clogs the pipeline.
    function test_ReceiveMessage_FailureDoesNotBlockNextMessage() public {
        FlakyTarget flaky = new FlakyTarget();
        flaky.setShouldRevert(true);

        IGovernanceVoting.ProposedAction memory failingAction = IGovernanceVoting.ProposedAction({
            target: address(flaky),
            data: abi.encodeCall(FlakyTarget.run, ()),
            value: 0
        });
        IGovernanceVoting.ProposedAction memory goodAction = _buildIncrementAction();

        _mockParseAndVerify(_buildVaa(_encodePayload(failingAction), 0));
        vm.expectRevert(abi.encodeWithSelector(FlakyTarget.TargetRevert.selector));
        governance.receiveMessage("");
        assertEq(governance.nextMinimumSequence(), 0);

        _mockParseAndVerify(_buildVaa(_encodePayload(_wrap(goodAction), 2), 1));
        governance.receiveMessage("");

        assertEq(counter.value(), 1);
        assertEq(governance.nextMinimumSequence(), 2);
    }

    /// @notice Recovery from a failed action can be a re-delivery of the same VAA (it was not
    ///     consumed): a value-carrying action with an unfunded governance fails once, then
    ///     succeeds once re-delivered after funding.
    function test_ReceiveMessage_FailedAction_RecoveredByRedelivery() public {
        address recipient = address(0xBEEF);
        IGovernanceVoting.ProposedAction memory action = IGovernanceVoting.ProposedAction({
            target: recipient,
            data: "",
            value: 0.25 ether
        });

        // the governance holds no native balance: the action reverts and is not consumed
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0));
        vm.expectRevert();
        governance.receiveMessage("");
        assertEq(recipient.balance, 0);
        assertEq(governance.nextMinimumSequence(), 0);

        // fund the governance and re-deliver the same VAA: it now executes
        vm.deal(address(governance), 0.25 ether);
        governance.receiveMessage("");

        assertEq(recipient.balance, 0.25 ether);
        assertEq(address(governance).balance, 0);
    }

    function test_ReceiveMessage_PaysActionValueFromGovernanceBalance() public {
        address recipient = address(0xBEEF);
        vm.deal(address(governance), 1 ether);

        IGovernanceVoting.ProposedAction memory action = IGovernanceVoting.ProposedAction({
            target: recipient,
            data: "",
            value: 0.25 ether
        });
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0));

        governance.receiveMessage("");
        assertEq(recipient.balance, 0.25 ether);
        assertEq(address(governance).balance, 0.75 ether);
    }

    /// @notice A single message carries a batch of actions, executed in order: the typical
    ///     case of coupling an adapter upgrade with an implementation upgrade lands atomically.
    function test_ReceiveMessage_BatchActions_ExecuteInOrder() public {
        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](3);
        actions[0] = _buildIncrementAction();
        actions[1] = IGovernanceVoting.ProposedAction({
            target: address(counter),
            data: abi.encodeCall(Counter.setValue, (42)),
            value: 0
        });
        actions[2] = _buildIncrementAction();
        _mockParseAndVerify(_buildVaa(_encodePayload(actions, 1), 0));

        governance.receiveMessage("");
        assertEq(counter.value(), 43);
        assertEq(governance.nextMinimumSequence(), 1);
    }

    /// @notice A batch can upgrade the receiver itself: implementation and strategy are swapped
    ///     through self-targeted actions, exercising the same onlyGovernance path as local voting.
    function test_ReceiveMessage_BatchWithSelfUpgrades_Executes() public {
        CrosschainHarness newImpl = new CrosschainHarness();
        RigoblockGovernanceStrategy newStrategy = new RigoblockGovernanceStrategy(STAKING, WORMHOLE, TARGET_CHAIN);

        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](2);
        actions[0] = IGovernanceVoting.ProposedAction({
            target: address(governance),
            data: abi.encodeCall(IGovernanceUpgrade.upgradeImplementation, (address(newImpl))),
            value: 0
        });
        actions[1] = IGovernanceVoting.ProposedAction({
            target: address(governance),
            data: abi.encodeCall(IGovernanceUpgrade.upgradeStrategy, (address(newStrategy))),
            value: 0
        });
        _mockParseAndVerify(_buildVaa(_encodePayload(actions, 1), 0));

        governance.receiveMessage("");
        assertEq(governance.implementation(), address(newImpl));
        assertEq(governance.governanceParameters().params.strategy, address(newStrategy));
    }

    /// @notice Voting thresholds can also be upgraded cross-chain through the self-call path.
    function test_ReceiveMessage_UpgradesThresholds_ViaSelfCall() public {
        address grg = address(0x2222);
        vm.mockCall(STAKING, abi.encodeWithSelector(IStaking.getGrgContract.selector), abi.encode(grg));
        vm.mockCall(grg, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(40_000_000e18)));

        uint256 proposalThreshold = 500_000e18;
        uint256 quorumThreshold = 2_000_000e18;
        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](1);
        actions[0] = IGovernanceVoting.ProposedAction({
            target: address(governance),
            data: abi.encodeCall(IGovernanceUpgrade.updateThresholds, (proposalThreshold, quorumThreshold)),
            value: 0
        });
        _mockParseAndVerify(_buildVaa(_encodePayload(actions, 1), 0));

        governance.receiveMessage("");
        IGovernanceState.GovernanceParameters memory params = governance.governanceParameters().params;
        assertEq(params.proposalThreshold, proposalThreshold);
        assertEq(params.quorumThreshold, quorumThreshold);
    }

    /// @notice A message older than the execution window reverts with GovReceiverMessageExpired
    ///     and is not consumed: it can never become executable years later, and the next
    ///     sequence still delivers, so it does not clog the pipeline.
    function test_ReceiveMessage_ExpiredMessage_RevertsAndDoesNotClog() public {
        vm.warp(1_700_000_000);
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0, uint32(block.timestamp - 3 days)));

        vm.expectRevert(abi.encodeWithSelector(IGovernanceCrosschain.GovReceiverMessageExpired.selector, uint64(0)));
        governance.receiveMessage("");
        assertEq(counter.value(), 0);
        assertEq(governance.nextMinimumSequence(), 0);

        // the next message executes: the expired one did not clog the pipeline
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 1));
        governance.receiveMessage("");
        assertEq(counter.value(), 1);
        assertEq(governance.nextMinimumSequence(), 2);

        // the expired message stays expired: after seq 1 executed, its sequence is also stale
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0, uint32(block.timestamp - 3 days)));
        vm.expectRevert(abi.encodeWithSelector(IGovernanceCrosschain.GovReceiverInvalidSequence.selector, 0, 2));
        governance.receiveMessage("");
    }

    /// @notice Expiry is not permanent data loss: the sender chain re-sends the action with a
    ///     fresh timestamp and the new message executes.
    function test_ReceiveMessage_ExpiredMessage_ResentWithFreshTimestamp_Executes() public {
        vm.warp(1_700_000_000);
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0, uint32(block.timestamp - 3 days)));
        vm.expectRevert(abi.encodeWithSelector(IGovernanceCrosschain.GovReceiverMessageExpired.selector, uint64(0)));
        governance.receiveMessage("");
        assertEq(counter.value(), 0);

        _mockParseAndVerify(_buildVaa(_encodePayload(_wrap(action), 2), 1));
        governance.receiveMessage("");
        assertEq(counter.value(), 1);
    }

    /// @notice A failed call inside a batch reverts the whole message atomically: nothing
    ///     executes and the sequence does not advance.
    function test_ReceiveMessage_FailedCallInBatch_RevertsAtomically() public {
        FlakyTarget flaky = new FlakyTarget();
        flaky.setShouldRevert(true);

        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](2);
        actions[0] = IGovernanceVoting.ProposedAction({
            target: address(flaky),
            data: abi.encodeCall(FlakyTarget.run, ()),
            value: 0
        });
        actions[1] = _buildIncrementAction();
        _mockParseAndVerify(_buildVaa(_encodePayload(actions, 1), 0));

        vm.expectRevert(abi.encodeWithSelector(FlakyTarget.TargetRevert.selector));
        governance.receiveMessage("");

        assertEq(counter.value(), 0);
        assertEq(governance.nextMinimumSequence(), 0);
    }

    function test_ReceiveMessage_ExecutesOnlyGovernanceAction() public {
        // an action calling the governance itself executes with msg.sender == governance,
        // i.e. the sender chain holds the same authority as local voters
        CrosschainHarness newImpl = new CrosschainHarness();
        IGovernanceVoting.ProposedAction memory action = IGovernanceVoting.ProposedAction({
            target: address(governance),
            data: abi.encodeCall(IGovernanceUpgrade.upgradeImplementation, (address(newImpl))),
            value: 0
        });
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0));

        governance.receiveMessage("");
        assertEq(governance.implementation(), address(newImpl));
    }

    /// @notice A receiver-chain governance is also a fully functional local governance: it can
    ///     receive cross-chain actions and, independently, make and execute its own proposals
    ///     with its own voting power (e.g. Arbitrum and the OP-stack chains).
    function test_LocalGovernance_CoexistsWithCrosschainReceive() public {
        // local voting power comes from the staking contract on this chain
        IStructs.StoredBalance memory balance = IStructs.StoredBalance({
            currentEpoch: 1,
            currentEpochBalance: uint96(DELEGATED_BALANCE),
            nextEpochBalance: uint96(DELEGATED_BALANCE)
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
            abi.encode(block.timestamp - 1)
        );
        vm.mockCall(STAKING, abi.encodeWithSelector(IStorage.epochDurationInSeconds.selector), abi.encode(7 days));

        // the cross-chain capability works...
        _mockParseAndVerify(_buildVaa(_encodePayload(_buildIncrementAction()), 0));
        governance.receiveMessage("");
        assertEq(counter.value(), 1);
        assertEq(governance.nextMinimumSequence(), 1);

        // ...and so does local governance on the same contract
        governance.setParams(1, 1);
        IGovernanceVoting.ProposedAction[] memory actions = new IGovernanceVoting.ProposedAction[](1);
        actions[0] = _buildIncrementAction();
        vm.prank(whale);
        uint256 proposalId = governance.propose(actions, "local proposal");

        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        governance.castVote(proposalId, uint8(IGovernanceVoting.VoteType.For));
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(IGovernanceState.ProposalStatus.Qualified));

        vm.warp(block.timestamp + 1);
        governance.execute(proposalId);
        assertEq(counter.value(), 2);
        assertEq(uint256(governance.getProposalState(proposalId)), uint256(IGovernanceState.ProposalStatus.Executed));
    }
}
