// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.35;

import {IRigoblockGovernance} from "../IRigoblockGovernance.sol";
import {IGovernanceCrosschain} from "../interfaces/governance/IGovernanceCrosschain.sol";
import {ICoreBridge, CoreBridgeVM} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";

/// @title CrosschainReceiver - Executes governance actions received from Wormhole.
/// @notice Deployed on target chains (e.g. HyperEVM). Each receiver is configured with
///         a trusted Wormhole emitter (the Ethereum mainnet Rigoblock governance proxy)
///         and executes the actions it sends in the same order they were published.
contract CrosschainReceiver {
    /// @notice Wormhole core contract on the current chain.
    ICoreBridge public immutable wormhole;

    /// @notice Wormhole chain id of the trusted source governance.
    uint16 public immutable emitterChainId;

    /// @notice Trusted source governance address, formatted as a Wormhole address.
    bytes32 public immutable emitterAddress;

    /// @notice Next Wormhole sequence expected to be executed.
    uint64 public expectedSequence;

    /// @notice Verified VAA hashes that have already been executed.
    mapping(bytes32 vaaHash => bool executed) public consumed;

    /// @notice Out-of-order messages queued by Wormhole sequence until their predecessors arrive.
    mapping(uint64 sequence => bytes encodedPayload) public queuedPayloads;

    /// @notice Thrown when the Wormhole core contract reports an invalid VAA.
    error GovReceiverInvalidVaa(string reason);

    /// @notice Thrown when the VAA emitter is not the trusted mainnet governance proxy.
    error GovReceiverUnknownEmitter();

    /// @notice Thrown when a VAA has already been consumed.
    error GovReceiverAlreadyConsumed(bytes32 vaaHash);

    /// @notice Thrown when the VAA is intended for a different target chain.
    error GovReceiverWrongChain(uint16 targetChainId, uint16 localChainId);

    /// @notice Thrown when the VAA sequence is lower than the expected next sequence.
    error GovReceiverSequenceTooOld(uint64 sequence, uint64 expectedSequence);

    /// @notice Thrown when the target action reverts during execution.
    error GovReceiverExecutionFailed(bytes reason);

    /// @notice Thrown when the Wormhole address is zero.
    error GovReceiverInvalidWormhole();

    /// @notice Thrown when the emitter chain id is the same as the local chain.
    error GovReceiverLocalEmitter(uint16 chainId);

    /// @param wormhole_ Address of the Wormhole core contract on this chain.
    /// @param emitterChainId_ Wormhole chain id of the trusted source governance.
    /// @param emitterAddress_ Trusted source governance address as a Wormhole address.
    constructor(address wormhole_, uint16 emitterChainId_, bytes32 emitterAddress_) {
        require(wormhole_ != address(0), GovReceiverInvalidWormhole());

        wormhole = ICoreBridge(wormhole_);
        emitterChainId = emitterChainId_;
        emitterAddress = emitterAddress_;
        expectedSequence = 1;
    }

    receive() external payable {}

    /// @notice Consumes a Wormhole VAA and executes the governance action it contains.
    /// @dev Mirrors the Wormhole HelloWorld example checks:
    ///      1. parseAndVerifyVM validates the guardian-set signature proof.
    ///      2. The receiver asserts `valid` is true.
    ///      3. The receiver asserts the emitter chain id and emitter address.
    ///      4. A consumed mapping protects against replay.
    ///      5. The payload's target chain is verified against the local chain.
    ///      Ordered execution uses Wormhole's per-emitter sequence number.
    /// @param encodedMessage The raw verified VAA bytes.
    function receiveMessage(bytes memory encodedMessage) public {
        // HelloWorld step 1: verify the VAA. Forged or malformed messages return valid == false.
        (CoreBridgeVM memory verifiedVaa, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedMessage);
        require(valid, GovReceiverInvalidVaa(reason));

        // HelloWorld step 2: assert the emitter is the trusted source governance.
        require(
            verifiedVaa.emitterChainId == emitterChainId && verifiedVaa.emitterAddress == emitterAddress,
            GovReceiverUnknownEmitter()
        );

        uint16 localChainId = wormhole.chainId();

        // HelloWorld registerEmitter guard: a receiver must not accept messages from its own chain.
        require(verifiedVaa.emitterChainId != localChainId, GovReceiverLocalEmitter(localChainId));

        // HelloWorld step 3: replay protection using the verified VAA hash.
        require(!consumed[verifiedVaa.hash], GovReceiverAlreadyConsumed(verifiedVaa.hash));

        IGovernanceCrosschain.CrossChainPayload memory payload = abi.decode(
            verifiedVaa.payload,
            (IGovernanceCrosschain.CrossChainPayload)
        );

        // Step 4: prevent the same VAA from being executed on the wrong chain.
        require(
            payload.targetWormholeChainId == localChainId,
            GovReceiverWrongChain(payload.targetWormholeChainId, localChainId)
        );

        // Mark the VAA consumed only after emitter and target-chain checks pass.
        // This prevents a VAA intended for a different chain from being burned here.
        consumed[verifiedVaa.hash] = true;

        uint64 sequence = verifiedVaa.sequence;
        require(sequence >= expectedSequence, GovReceiverSequenceTooOld(sequence, expectedSequence));

        if (sequence > expectedSequence) {
            queuedPayloads[sequence] = abi.encode(payload);
            return;
        }

        _executeAction(sequence, payload.action);
        expectedSequence = sequence + 1;

        // Process queued messages that are now ready in order.
        while (queuedPayloads[expectedSequence].length != 0) {
            IGovernanceCrosschain.CrossChainPayload memory queuedPayload = abi.decode(
                queuedPayloads[expectedSequence],
                (IGovernanceCrosschain.CrossChainPayload)
            );
            delete queuedPayloads[expectedSequence];
            _executeAction(expectedSequence, queuedPayload.action);
            expectedSequence++;
        }
    }

    /// @dev Executes a single action using a low-level call.
    function _executeAction(uint64 sequence, IRigoblockGovernance.ProposedAction memory action) private {
        (bool success, bytes memory returndata) = action.target.call{value: action.value}(action.data);
        require(success, GovReceiverExecutionFailed(returndata));

        emit IGovernanceCrosschain.CrossChainActionExecuted(sequence, keccak256(abi.encode(action)));
    }
}
