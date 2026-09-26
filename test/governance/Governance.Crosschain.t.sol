// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {CrossChainPayload} from "../../contracts/governance/types/GovernanceTypes.sol";
import {ICrosschainReceiver} from "../../contracts/governance/interfaces/ICrosschainReceiver.sol";
import {IGovernanceUpgrade} from "../../contracts/governance/interfaces/governance/IGovernanceUpgrade.sol";
import {IGovernanceVoting} from "../../contracts/governance/interfaces/governance/IGovernanceVoting.sol";
import {RigoblockGovernance} from "../../contracts/governance/RigoblockGovernance.sol";
import {RigoblockGovernanceStrategy} from "../../contracts/governance/strategies/RigoblockGovernanceStrategy.sol";

import {Test} from "forge-std/Test.sol";
import {ICoreBridge, CoreBridgeVM, GuardianSignature} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";
import {CHAIN_ID_ETHEREUM, CHAIN_ID_HYPER_EVM} from "wormhole-solidity-sdk/src/constants/Chains.sol";
import {Constants} from "../../contracts/test/Constants.sol";

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

/// @dev Reenters retryFailedAction from inside the retried action's execution.
contract ReentrantRetryTarget {
    uint256 public calls;
    bool public reentrySucceeded;
    bytes public reentryError;

    function run() external payable {
        calls++;
        if (calls == 1) {
            try ICrosschainReceiver(msg.sender).retryFailedAction(0) {
                reentrySucceeded = true;
            } catch (bytes memory err) {
                reentryError = err;
            }
        }
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

    function implementation() external view returns (address) {
        return _implementation().value;
    }
}

/// @title Tests for the cross-chain receiver implemented inside the governance.
/// @notice Wormhole's parseAndVerifyVM is mocked: these tests exercise the governance's own
///     state machine (ordering, queueing, replay protection, failure deferral), not VAA cryptography.
contract GovernanceCrosschainTest is Test {
    uint16 internal constant EMITTER_CHAIN = CHAIN_ID_ETHEREUM;
    uint16 internal constant TARGET_CHAIN = CHAIN_ID_HYPER_EVM;
    address internal constant STAKING = address(0x1111);
    address internal constant WORMHOLE = Constants.WORMHOLE_HYPEREVM;
    bytes32 internal constant EMITTER_ADDRESS = bytes32(uint256(uint160(Constants.GOV_PROXY)));

    CrosschainHarness internal governance;
    RigoblockGovernanceStrategy internal strategy;
    Counter internal counter;

    function setUp() public {
        strategy = new RigoblockGovernanceStrategy(STAKING, WORMHOLE, TARGET_CHAIN);
        governance = new CrosschainHarness();
        governance.setStrategy(address(strategy));
        counter = new Counter();
    }

    function _encodePayload(IGovernanceVoting.ProposedAction memory action) private pure returns (bytes memory) {
        return _encodePayload(action, 1);
    }

    function _encodePayload(
        IGovernanceVoting.ProposedAction memory action,
        uint256 proposalId
    ) private pure returns (bytes memory) {
        return
            abi.encode(
                CrossChainPayload({targetWormholeChainId: TARGET_CHAIN, proposalId: proposalId, action: action})
            );
    }

    function _buildVaa(bytes memory payload, uint64 sequence) private view returns (CoreBridgeVM memory) {
        return
            CoreBridgeVM({
                version: 1,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: EMITTER_CHAIN,
                emitterAddress: EMITTER_ADDRESS,
                sequence: sequence,
                consistencyLevel: 1,
                payload: payload,
                guardianSetIndex: 0,
                signatures: new GuardianSignature[](0),
                hash: keccak256(payload)
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

    function test_ReceiveMessage_HappyPath() public {
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);
        _mockParseAndVerify(_buildVaa(payload, 0));

        governance.receiveMessage("");
        assertEq(counter.value(), 1);
        assertEq(governance.expectedSequence(), 1);
    }

    function test_ReceiveMessage_NotConfigured_Reverts() public {
        CrosschainHarness unconfigured = new CrosschainHarness();

        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0));

        vm.expectRevert(ICrosschainReceiver.GovReceiverNotConfigured.selector);
        unconfigured.receiveMessage("");
    }

    function test_ReceiveMessage_WormholeDisabledInStrategy_Reverts() public {
        CrosschainHarness otherChain = new CrosschainHarness();
        // a strategy with a zero Wormhole address (e.g. a chain that is not a receiver)
        otherChain.setStrategy(address(new RigoblockGovernanceStrategy(STAKING, address(0), TARGET_CHAIN)));

        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0));

        vm.expectRevert(ICrosschainReceiver.GovReceiverNotConfigured.selector);
        otherChain.receiveMessage("");
    }

    function test_ReceiveMessage_UnknownEmitter_Reverts() public {
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);
        CoreBridgeVM memory vaa = _buildVaa(payload, 0);
        vaa.emitterAddress = bytes32(uint256(1));
        _mockParseAndVerify(vaa);

        vm.expectRevert(ICrosschainReceiver.GovReceiverUnknownEmitter.selector);
        governance.receiveMessage("");
    }

    function test_ReceiveMessage_UnknownEmitterChain_Reverts() public {
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);
        CoreBridgeVM memory vaa = _buildVaa(payload, 0);
        vaa.emitterChainId = EMITTER_CHAIN + 1;
        _mockParseAndVerify(vaa);

        vm.expectRevert(ICrosschainReceiver.GovReceiverUnknownEmitter.selector);
        governance.receiveMessage("");
    }

    function test_ReceiveMessage_WrongChain_Reverts() public {
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = abi.encode(
            CrossChainPayload({targetWormholeChainId: 9999, proposalId: 1, action: action})
        );
        _mockParseAndVerify(_buildVaa(payload, 0));

        vm.expectRevert(
            abi.encodeWithSelector(
                ICrosschainReceiver.GovReceiverWrongChain.selector,
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

        vm.expectRevert(abi.encodeWithSelector(ICrosschainReceiver.GovReceiverLocalEmitter.selector, EMITTER_CHAIN));
        governance.receiveMessage("");
    }

    function test_ReceiveMessage_AlreadyConsumed_Reverts() public {
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);
        _mockParseAndVerify(_buildVaa(payload, 0));

        governance.receiveMessage("");

        vm.expectRevert(
            abi.encodeWithSelector(ICrosschainReceiver.GovReceiverAlreadyConsumed.selector, keccak256(payload))
        );
        governance.receiveMessage("");
    }

    function test_ReceiveMessage_OutOfOrder_QueuesAndExecutesInOrder() public {
        IGovernanceVoting.ProposedAction memory action1 = _buildIncrementAction();
        IGovernanceVoting.ProposedAction memory action2 = IGovernanceVoting.ProposedAction({
            target: address(counter),
            data: abi.encodeCall(Counter.setValue, (42)),
            value: 0
        });

        bytes memory payload1 = _encodePayload(action1);
        bytes memory payload2 = _encodePayload(action2);

        // Deliver Wormhole sequence 1 first.
        _mockParseAndVerify(_buildVaa(payload2, 1));
        governance.receiveMessage("");
        assertEq(counter.value(), 0);
        assertGt(governance.queuedPayloads(1).length, 0);

        // Deliver sequence 0: both execute in order.
        _mockParseAndVerify(_buildVaa(payload1, 0));
        governance.receiveMessage("");
        assertEq(counter.value(), 42);
        assertEq(governance.queuedPayloads(1).length, 0);
        assertEq(governance.expectedSequence(), 2);
    }

    function test_ReceiveMessage_SequenceTooOld_Reverts() public {
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);

        // First valid message with sequence 0.
        _mockParseAndVerify(_buildVaa(payload, 0));
        governance.receiveMessage("");
        assertEq(governance.expectedSequence(), 1);

        // A different VAA with the same sequence 0 is now too old and not a replay.
        IGovernanceVoting.ProposedAction memory staleAction = IGovernanceVoting.ProposedAction({
            target: address(counter),
            data: abi.encodeCall(Counter.setValue, (42)),
            value: 0
        });
        bytes memory stalePayload = _encodePayload(staleAction);
        _mockParseAndVerify(_buildVaa(stalePayload, 0));
        vm.expectRevert(
            abi.encodeWithSelector(ICrosschainReceiver.GovReceiverSequenceTooOld.selector, uint64(0), uint64(1))
        );
        governance.receiveMessage("");
    }

    function test_ReceiveMessage_InvalidVaa_Reverts() public {
        vm.mockCall(
            WORMHOLE,
            abi.encodeWithSelector(ICoreBridge.parseAndVerifyVM.selector),
            abi.encode(_buildVaa("", 0), false, "invalid signature")
        );

        vm.expectRevert(
            abi.encodeWithSelector(ICrosschainReceiver.GovReceiverInvalidVaa.selector, "invalid signature")
        );
        governance.receiveMessage("");
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

    function test_ReceiveMessage_ExecutionFailure_DefersWithoutReverting() public {
        FlakyTarget flaky = new FlakyTarget();
        flaky.setShouldRevert(true);
        IGovernanceVoting.ProposedAction memory action = IGovernanceVoting.ProposedAction({
            target: address(flaky),
            data: abi.encodeCall(FlakyTarget.run, ()),
            value: 0
        });
        bytes memory payload = _encodePayload(action);
        _mockParseAndVerify(_buildVaa(payload, 0));

        vm.expectEmit(true, true, true, true);
        emit ICrosschainReceiver.CrossChainActionFailed(
            0,
            keccak256(abi.encode(action)),
            abi.encodeWithSelector(FlakyTarget.TargetRevert.selector)
        );
        governance.receiveMessage("");

        // the pipeline advances past the failure and records it for retry
        assertEq(governance.expectedSequence(), 1);
        IGovernanceVoting.ProposedAction memory failed = governance.failedActions(0);
        assertEq(failed.target, address(flaky));
    }

    function test_RetryFailedAction_ExecutesOncePreconditionFixed() public {
        FlakyTarget flaky = new FlakyTarget();
        flaky.setShouldRevert(true);
        IGovernanceVoting.ProposedAction memory action = IGovernanceVoting.ProposedAction({
            target: address(flaky),
            data: abi.encodeCall(FlakyTarget.run, ()),
            value: 0
        });
        bytes memory payload = _encodePayload(action);
        _mockParseAndVerify(_buildVaa(payload, 0));
        governance.receiveMessage("");
        assertEq(governance.expectedSequence(), 1);

        // retry while the target still reverts
        vm.expectRevert(
            abi.encodeWithSelector(
                ICrosschainReceiver.GovReceiverExecutionFailed.selector,
                abi.encodeWithSelector(FlakyTarget.TargetRevert.selector)
            )
        );
        governance.retryFailedAction(0);

        // fix the precondition, then anyone can retry
        flaky.setShouldRevert(false);
        governance.retryFailedAction(0);

        IGovernanceVoting.ProposedAction memory failed = governance.failedActions(0);
        assertEq(failed.target, address(0));
    }

    function test_RetryFailedAction_NothingToRetry_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ICrosschainReceiver.GovReceiverNothingToRetry.selector, uint64(7)));
        governance.retryFailedAction(7);
    }

    function test_ReceiveMessage_QueuedFailure_DoesNotRollBackDelivery() public {
        // sequence 1 carries a reverting action and is relayed before sequence 0
        FlakyTarget flaky = new FlakyTarget();
        flaky.setShouldRevert(true);
        IGovernanceVoting.ProposedAction memory failingAction = IGovernanceVoting.ProposedAction({
            target: address(flaky),
            data: abi.encodeCall(FlakyTarget.run, ()),
            value: 0
        });
        IGovernanceVoting.ProposedAction memory goodAction = _buildIncrementAction();

        _mockParseAndVerify(_buildVaa(_encodePayload(failingAction), 1));
        governance.receiveMessage("");
        assertEq(governance.expectedSequence(), 0);

        // delivering sequence 0 succeeds even though draining sequence 1 fails
        _mockParseAndVerify(_buildVaa(_encodePayload(goodAction), 0));
        governance.receiveMessage("");
        assertEq(counter.value(), 1);
        assertEq(governance.expectedSequence(), 2);
        IGovernanceVoting.ProposedAction memory failed = governance.failedActions(1);
        assertEq(failed.target, address(flaky));
    }

    function test_ReceiveMessage_QueueDrain_IsCappedPerCall() public {
        // queue sequences 1..9 (9 messages) behind sequence 0, each with a unique payload
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        for (uint64 sequence = 1; sequence <= 9; sequence++) {
            _mockParseAndVerify(_buildVaa(_encodePayload(action, sequence), sequence));
            governance.receiveMessage("");
        }
        assertEq(governance.expectedSequence(), 0);

        // delivering sequence 0 executes it and drains at most 8 queued messages
        _mockParseAndVerify(_buildVaa(_encodePayload(action, 0), 0));
        governance.receiveMessage("");
        assertEq(governance.expectedSequence(), 9);
        assertEq(counter.value(), 9);
        assertGt(governance.queuedPayloads(9).length, 0);

        // the remainder drains lazily on the next delivery
        _mockParseAndVerify(_buildVaa(_encodePayload(action, 10), 10));
        governance.receiveMessage("");
        assertEq(governance.expectedSequence(), 11);
        assertEq(counter.value(), 11);
        assertEq(governance.queuedPayloads(10).length, 0);
    }

    function test_ReceiveMessage_WrongChain_DoesNotConsumeVaa() public {
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = abi.encode(
            CrossChainPayload({targetWormholeChainId: 9999, proposalId: 1, action: action})
        );
        CoreBridgeVM memory vaa = _buildVaa(payload, 0);
        _mockParseAndVerify(vaa);

        vm.expectRevert(
            abi.encodeWithSelector(
                ICrosschainReceiver.GovReceiverWrongChain.selector,
                uint16(9999),
                uint16(TARGET_CHAIN)
            )
        );
        governance.receiveMessage("");

        // the VAA is not burned here: it must remain usable on its intended chain
        assertFalse(governance.consumed(vaa.hash));
    }

    function test_ReceiveMessage_MalformedPayload_Reverts() public {
        CoreBridgeVM memory vaa = _buildVaa(hex"1234", 0);
        _mockParseAndVerify(vaa);

        vm.expectRevert();
        governance.receiveMessage("");

        assertFalse(governance.consumed(vaa.hash));
    }

    function test_ReceiveMessage_InsufficientBalanceForValue_Defers() public {
        address recipient = address(0xBEEF);
        // the governance has no ETH: the value-carrying action cannot execute
        IGovernanceVoting.ProposedAction memory action = IGovernanceVoting.ProposedAction({
            target: recipient,
            data: "",
            value: 0.25 ether
        });
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0));

        governance.receiveMessage("");
        assertEq(recipient.balance, 0);
        IGovernanceVoting.ProposedAction memory failed = governance.failedActions(0);
        assertEq(failed.target, recipient);
        assertEq(failed.value, 0.25 ether);

        // funding the governance makes the action retriable by anyone
        vm.deal(address(governance), 0.25 ether);
        governance.retryFailedAction(0);
        assertEq(recipient.balance, 0.25 ether);
    }

    function test_RetryFailedAction_ReentrantRetry_CannotReExecute() public {
        ReentrantRetryTarget target = new ReentrantRetryTarget();
        IGovernanceVoting.ProposedAction memory action = IGovernanceVoting.ProposedAction({
            target: address(target),
            data: abi.encodeCall(ReentrantRetryTarget.run, ()),
            value: 0.5 ether
        });
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 0));
        governance.receiveMessage("");
        assertEq(governance.failedActions(0).target, address(target));

        vm.deal(address(governance), 1 ether);
        governance.retryFailedAction(0);

        // the reentrant retry found nothing to retry: the entry is cleared before the call
        assertFalse(target.reentrySucceeded());
        assertEq(
            target.reentryError(),
            abi.encodeWithSelector(ICrosschainReceiver.GovReceiverNothingToRetry.selector, uint64(0))
        );
        assertEq(target.calls(), 1);
        // the action value is paid out exactly once; the reentrant attempt got nothing
        assertEq(address(governance).balance, 0.5 ether);
        assertEq(address(target).balance, 0.5 ether);
        assertEq(governance.failedActions(0).target, address(0));
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
}
