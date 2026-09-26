// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;
import {CrossChainPayload} from "../../contracts/governance/types/GovernanceTypes.sol";
import {IGovernanceVoting} from "../../contracts/governance/interfaces/governance/IGovernanceVoting.sol";

import {Test} from "forge-std/Test.sol";
import {ICoreBridge, CoreBridgeVM, GuardianSignature} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";
import {CHAIN_ID_ETHEREUM, CHAIN_ID_HYPER_EVM} from "wormhole-solidity-sdk/src/constants/Chains.sol";
import {CrosschainReceiver} from "../../contracts/governance/crosschain/CrosschainReceiver.sol";
import {CrosschainReceiverProxy} from "../../contracts/governance/proxies/CrosschainReceiverProxy.sol";
import {IGovernanceVoting} from "../../contracts/governance/interfaces/governance/IGovernanceVoting.sol";
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

contract InitializableReceiver {
    error MockFail();

    uint256 public initializedValue;

    function initialize(uint256 newValue) external {
        initializedValue = newValue;
    }

    function fail() external pure {
        revert MockFail();
    }
}

contract CrosschainReceiverTest is Test {
    uint16 internal constant EMITTER_CHAIN = CHAIN_ID_ETHEREUM;
    uint16 internal constant TARGET_CHAIN = CHAIN_ID_HYPER_EVM;
    address internal constant WORMHOLE = Constants.WORMHOLE_HYPEREVM;
    bytes32 internal constant EMITTER_ADDRESS = bytes32(uint256(uint160(Constants.GOV_PROXY)));
    address internal constant OWNER = address(0xB0B);

    CrosschainReceiver internal receiver;
    Counter internal counter;

    function setUp() public {
        CrosschainReceiver implementation = new CrosschainReceiver(WORMHOLE, EMITTER_CHAIN, EMITTER_ADDRESS);
        receiver = CrosschainReceiver(payable(address(new CrosschainReceiverProxy(address(implementation), OWNER))));
        counter = new Counter();

        vm.mockCall(WORMHOLE, abi.encodeWithSelector(ICoreBridge.chainId.selector), abi.encode(TARGET_CHAIN));
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
        _mockParseAndVerify(_buildVaa(payload, 1));

        receiver.receiveMessage("");
        assertEq(counter.value(), 1);
        assertEq(receiver.expectedSequence(), 2);
    }

    function test_Initialize_CannotBeReplayed() public {
        vm.expectRevert(CrosschainReceiver.GovReceiverAlreadyInitialized.selector);
        receiver.initialize();
    }

    function test_ReceiveMessage_UnknownEmitter_Reverts() public {
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);
        CoreBridgeVM memory vaa = _buildVaa(payload, 1);
        vaa.emitterAddress = bytes32(uint256(1));
        _mockParseAndVerify(vaa);

        vm.expectRevert(CrosschainReceiver.GovReceiverUnknownEmitter.selector);
        receiver.receiveMessage("");
    }

    function test_ReceiveMessage_WrongChain_Reverts() public {
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = abi.encode(
            CrossChainPayload({targetWormholeChainId: 9999, proposalId: 1, action: action})
        );
        _mockParseAndVerify(_buildVaa(payload, 1));

        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainReceiver.GovReceiverWrongChain.selector,
                uint16(9999),
                uint16(TARGET_CHAIN)
            )
        );
        receiver.receiveMessage("");
    }

    function test_ReceiveMessage_LocalEmitter_Reverts() public {
        // Simulate the receiver being deployed on the same chain as the emitter.
        vm.mockCall(WORMHOLE, abi.encodeWithSelector(ICoreBridge.chainId.selector), abi.encode(EMITTER_CHAIN));

        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);
        _mockParseAndVerify(_buildVaa(payload, 1));

        vm.expectRevert(
            abi.encodeWithSelector(CrosschainReceiver.GovReceiverLocalEmitter.selector, uint16(EMITTER_CHAIN))
        );
        receiver.receiveMessage("");
    }

    function test_ReceiveMessage_AlreadyConsumed_Reverts() public {
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);
        _mockParseAndVerify(_buildVaa(payload, 1));

        receiver.receiveMessage("");

        vm.expectRevert(
            abi.encodeWithSelector(CrosschainReceiver.GovReceiverAlreadyConsumed.selector, keccak256(payload))
        );
        receiver.receiveMessage("");
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

        // Deliver Wormhole sequence 2 first.
        _mockParseAndVerify(_buildVaa(payload2, 2));
        receiver.receiveMessage("");
        assertEq(counter.value(), 0);
        assertGt(receiver.queuedPayloads(2).length, 0);

        // Deliver sequence 1: both execute in order.
        _mockParseAndVerify(_buildVaa(payload1, 1));
        receiver.receiveMessage("");
        assertEq(counter.value(), 42);
        assertEq(receiver.queuedPayloads(2).length, 0);
        assertEq(receiver.expectedSequence(), 3);
    }

    function test_ReceiveMessage_SequenceTooOld_Reverts() public {
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);

        // First valid message with sequence 1.
        _mockParseAndVerify(_buildVaa(payload, 1));
        receiver.receiveMessage("");
        assertEq(receiver.expectedSequence(), 2);

        // A different VAA with the same sequence 1 is now too old and not a replay.
        IGovernanceVoting.ProposedAction memory staleAction = IGovernanceVoting.ProposedAction({
            target: address(counter),
            data: abi.encodeCall(Counter.setValue, (42)),
            value: 0
        });
        bytes memory stalePayload = _encodePayload(staleAction);
        _mockParseAndVerify(_buildVaa(stalePayload, 1));
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainReceiver.GovReceiverSequenceTooOld.selector, uint64(1), uint64(2))
        );
        receiver.receiveMessage("");
    }

    function test_ReceiveMessage_InvalidVaa_Reverts() public {
        vm.mockCall(
            WORMHOLE,
            abi.encodeWithSelector(ICoreBridge.parseAndVerifyVM.selector),
            abi.encode(_buildVaa("", 0), false, "invalid signature")
        );

        vm.expectRevert(abi.encodeWithSelector(CrosschainReceiver.GovReceiverInvalidVaa.selector, "invalid signature"));
        receiver.receiveMessage("");
    }

    function test_Constructor_ZeroWormhole_Reverts() public {
        vm.expectRevert(CrosschainReceiver.GovReceiverInvalidWormhole.selector);
        new CrosschainReceiver(address(0), EMITTER_CHAIN, EMITTER_ADDRESS);
    }

    function test_Receive_HoldsNativeFunds() public {
        // the receiver must be able to hold native currency to execute actions with value
        (bool success, ) = address(receiver).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(receiver).balance, 1 ether);
    }

    function test_ReceiveMessage_UnknownEmitterChain_Reverts() public {
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        bytes memory payload = _encodePayload(action);
        CoreBridgeVM memory vaa = _buildVaa(payload, 1);
        vaa.emitterChainId = EMITTER_CHAIN + 1;
        _mockParseAndVerify(vaa);

        vm.expectRevert(CrosschainReceiver.GovReceiverUnknownEmitter.selector);
        receiver.receiveMessage("");
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
        _mockParseAndVerify(_buildVaa(payload, 1));

        vm.expectEmit(true, true, true, true);
        emit CrosschainReceiver.CrossChainActionFailed(
            1,
            keccak256(abi.encode(action)),
            abi.encodeWithSelector(FlakyTarget.TargetRevert.selector)
        );
        receiver.receiveMessage("");

        // the pipeline advances past the failure and records it for retry
        assertEq(receiver.expectedSequence(), 2);
        (address failedTarget, , ) = receiver.failedActions(1);
        assertEq(failedTarget, address(flaky));
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
        _mockParseAndVerify(_buildVaa(payload, 1));
        receiver.receiveMessage("");
        assertEq(receiver.expectedSequence(), 2);

        // retry while the target still reverts
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainReceiver.GovReceiverExecutionFailed.selector,
                abi.encodeWithSelector(FlakyTarget.TargetRevert.selector)
            )
        );
        receiver.retryFailedAction(1);

        // fix the precondition, then anyone can retry
        flaky.setShouldRevert(false);
        receiver.retryFailedAction(1);

        (address failedTarget, , ) = receiver.failedActions(1);
        assertEq(failedTarget, address(0));
    }

    function test_RetryFailedAction_NothingToRetry_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(CrosschainReceiver.GovReceiverNothingToRetry.selector, uint64(7)));
        receiver.retryFailedAction(7);
    }

    function test_ReceiveMessage_QueuedFailure_DoesNotRollBackDelivery() public {
        // sequence 2 carries a reverting action and is relayed before sequence 1
        FlakyTarget flaky = new FlakyTarget();
        flaky.setShouldRevert(true);
        IGovernanceVoting.ProposedAction memory failingAction = IGovernanceVoting.ProposedAction({
            target: address(flaky),
            data: abi.encodeCall(FlakyTarget.run, ()),
            value: 0
        });
        IGovernanceVoting.ProposedAction memory goodAction = _buildIncrementAction();

        _mockParseAndVerify(_buildVaa(_encodePayload(failingAction), 2));
        receiver.receiveMessage("");
        assertEq(receiver.expectedSequence(), 1);

        // delivering sequence 1 succeeds even though draining sequence 2 fails
        _mockParseAndVerify(_buildVaa(_encodePayload(goodAction), 1));
        receiver.receiveMessage("");
        assertEq(counter.value(), 1);
        assertEq(receiver.expectedSequence(), 3);
        (address failedTarget, , ) = receiver.failedActions(2);
        assertEq(failedTarget, address(flaky));
    }

    function test_ReceiveMessage_QueueDrain_IsCappedPerCall() public {
        // queue sequences 2..10 (9 messages) behind sequence 1, each with a unique payload
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        for (uint64 sequence = 2; sequence <= 10; sequence++) {
            _mockParseAndVerify(_buildVaa(_encodePayload(action, sequence), sequence));
            receiver.receiveMessage("");
        }
        assertEq(receiver.expectedSequence(), 1);

        // delivering sequence 1 executes it and drains at most 8 queued messages
        _mockParseAndVerify(_buildVaa(_encodePayload(action, 1), 1));
        receiver.receiveMessage("");
        assertEq(receiver.expectedSequence(), 10);
        assertEq(counter.value(), 9);
        assertGt(receiver.queuedPayloads(10).length, 0);

        // the remainder drains lazily on the next delivery
        _mockParseAndVerify(_buildVaa(_encodePayload(action, 11), 11));
        receiver.receiveMessage("");
        assertEq(receiver.expectedSequence(), 12);
        assertEq(counter.value(), 11);
        assertEq(receiver.queuedPayloads(11).length, 0);
    }

    function test_Proxy_UpgradeToAndCall_OnlyOwner() public {
        // consume a message so the receiver has state to preserve across the upgrade
        IGovernanceVoting.ProposedAction memory action = _buildIncrementAction();
        _mockParseAndVerify(_buildVaa(_encodePayload(action), 1));
        receiver.receiveMessage("");
        assertEq(receiver.expectedSequence(), 2);

        CrosschainReceiver newImplementation = new CrosschainReceiver(WORMHOLE, EMITTER_CHAIN, EMITTER_ADDRESS);

        vm.expectRevert(abi.encodeWithSelector(CrosschainReceiverProxy.ReceiverProxyNotOwner.selector, address(this)));
        CrosschainReceiverProxy(payable(address(receiver))).upgradeToAndCall(address(newImplementation), "");

        vm.prank(OWNER);
        CrosschainReceiverProxy(payable(address(receiver))).upgradeToAndCall(address(newImplementation), "");

        // state is preserved and the new implementation serves calls
        assertEq(receiver.expectedSequence(), 2);
        _mockParseAndVerify(_buildVaa(_encodePayload(action, 2), 2));
        receiver.receiveMessage("");
        assertEq(counter.value(), 2);
    }

    function test_Proxy_UpgradeToAndCall_RunsInitializer() public {
        InitializableReceiver implementation = new InitializableReceiver();
        CrosschainReceiverProxy proxy = new CrosschainReceiverProxy(address(implementation), OWNER);

        vm.prank(OWNER);
        proxy.upgradeToAndCall(address(implementation), abi.encodeCall(InitializableReceiver.initialize, (99)));
        assertEq(InitializableReceiver(address(proxy)).initializedValue(), 99);

        // a failing initializer reverts the whole upgrade, including the pointer update
        vm.expectRevert(InitializableReceiver.MockFail.selector);
        vm.prank(OWNER);
        proxy.upgradeToAndCall(address(implementation), abi.encodeCall(InitializableReceiver.fail, ()));
        assertEq(InitializableReceiver(address(proxy)).initializedValue(), 99);
    }

    function test_Proxy_Constructor_RejectsInvalidAddresses() public {
        CrosschainReceiver implementation = new CrosschainReceiver(WORMHOLE, EMITTER_CHAIN, EMITTER_ADDRESS);
        vm.expectRevert(CrosschainReceiverProxy.ReceiverProxyInvalidAddress.selector);
        new CrosschainReceiverProxy(address(implementation), address(0));

        vm.expectRevert(CrosschainReceiverProxy.ReceiverProxyInvalidAddress.selector);
        new CrosschainReceiverProxy(address(0), OWNER);
    }
}
