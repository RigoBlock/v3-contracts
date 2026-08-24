// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ICoreBridge, CoreBridgeVM, GuardianSignature} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";
import {CHAIN_ID_ETHEREUM, CHAIN_ID_HYPER_EVM} from "wormhole-solidity-sdk/src/constants/Chains.sol";
import {CrosschainReceiver} from "../../contracts/governance/crosschain/CrosschainReceiver.sol";
import {IGovernanceVoting} from "../../contracts/governance/interfaces/governance/IGovernanceVoting.sol";
import {IGovernanceCrosschain} from "../../contracts/governance/interfaces/governance/IGovernanceCrosschain.sol";
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

contract CrosschainReceiverTest is Test {
    uint16 internal constant EMITTER_CHAIN = CHAIN_ID_ETHEREUM;
    uint16 internal constant TARGET_CHAIN = CHAIN_ID_HYPER_EVM;
    address internal constant WORMHOLE = Constants.WORMHOLE_HYPEREVM;
    bytes32 internal constant EMITTER_ADDRESS = bytes32(uint256(uint160(Constants.GOV_PROXY)));

    CrosschainReceiver internal receiver;
    Counter internal counter;

    function setUp() public {
        receiver = new CrosschainReceiver(WORMHOLE, EMITTER_CHAIN, EMITTER_ADDRESS);
        counter = new Counter();

        vm.mockCall(WORMHOLE, abi.encodeWithSelector(ICoreBridge.chainId.selector), abi.encode(TARGET_CHAIN));
    }

    function _encodePayload(IGovernanceVoting.ProposedAction memory action) private pure returns (bytes memory) {
        return
            abi.encode(
                IGovernanceCrosschain.CrossChainPayload({
                    targetWormholeChainId: TARGET_CHAIN,
                    proposalId: 1,
                    action: action
                })
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
            IGovernanceCrosschain.CrossChainPayload({targetWormholeChainId: 9999, proposalId: 1, action: action})
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
}
