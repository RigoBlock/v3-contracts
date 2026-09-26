// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {CrossChainPayload} from "../types/GovernanceTypes.sol";
import {IGovernanceVoting} from "../interfaces/governance/IGovernanceVoting.sol";
import {ICoreBridge, CoreBridgeVM} from "wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol";

// TODO: this contract must inherit its own interface!
/// @title CrosschainReceiver - Executes governance actions received from Wormhole.
/// @notice Deployed behind a CrosschainReceiverProxy on target chains (e.g. HyperEVM). Each receiver
///         is configured with a trusted Wormhole emitter (the Ethereum mainnet Rigoblock governance
///         proxy) and executes the actions it sends in the same order they were published.
/// @dev A reverting action is skipped, not propagated: it is stored in failedActions, emitted as
///      CrossChainActionFailed, and can be re-executed via retryFailedAction once its preconditions
///      are fixed, so receiveMessage can never be bricked by target behavior. Unrecoverable states
///      (e.g. a Wormhole outage) are handled by upgrading the implementation through the proxy owner.
///      See docs/wormhole/GOVERNANCE_CROSSCHAIN.md.
contract CrosschainReceiver {
    /// @notice Maximum number of queued messages executed per receiveMessage call, bounding the gas
    ///         spent draining the queue; the remainder is processed by subsequent deliveries.
    uint256 private constant _MAX_QUEUE_DRAIN = 8;

    /// @notice Emitted when a cross-chain action is executed on the target chain.
    /// @param sequence Wormhole sequence number of the consumed VAA.
    /// @param actionHash keccak256 hash of the executed action.
    event CrossChainActionExecuted(uint64 sequence, bytes32 actionHash);

    /// @notice Emitted when a cross-chain action reverts on execution and is deferred for retry.
    /// @param sequence Wormhole sequence number of the consumed VAA.
    /// @param actionHash keccak256 hash of the failed action.
    /// @param reason Revert payload returned by the target.
    event CrossChainActionFailed(uint64 sequence, bytes32 actionHash, bytes reason);

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
    mapping(uint64 sequence => bytes encodedAction) public queuedPayloads;

    /// @notice Actions that reverted on execution, re-executable via retryFailedAction. An entry
    ///         exists iff its action.target is not the zero address.
    mapping(uint64 sequence => IGovernanceVoting.ProposedAction action) public failedActions;

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

    /// @notice Thrown when the target action reverts during a retry attempt.
    error GovReceiverExecutionFailed(bytes reason);

    /// @notice Thrown when retrying a sequence that has no failed action.
    error GovReceiverNothingToRetry(uint64 sequence);

    /// @notice Thrown when the Wormhole address is zero.
    error GovReceiverInvalidWormhole();

    /// @notice Thrown when the emitter chain id is the same as the local chain.
    error GovReceiverLocalEmitter(uint16 chainId);

    /// @notice Thrown when initialize is called on an already initialized receiver.
    error GovReceiverAlreadyInitialized();

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

    /// @notice Initializes the receiver behind a proxy.
    /// @dev Called via delegatecall by the proxy constructor. Cannot be replayed once expectedSequence
    ///      is non-zero, so the first valid sequence after initialization is 1.
    function initialize() external {
        require(expectedSequence == 0, GovReceiverAlreadyInitialized());
        expectedSequence = 1;
    }

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

        CrossChainPayload memory payload = abi.decode(verifiedVaa.payload, (CrossChainPayload));

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
            queuedPayloads[sequence] = abi.encode(payload.action);
        } else {
            _executeAction(sequence, payload.action);
            expectedSequence = sequence + 1;
        }

        // always attempt a drain, so a delivery that was queued still processes ready predecessors
        _drainQueue();
    }

    /// @notice Re-executes an action that previously reverted on execution.
    /// @dev Callable by anyone once the action's preconditions on this chain are satisfied. The
    ///      retried action executes at its original sequence position relative to already executed
    ///      actions; if strict ordering with later actions matters, governance re-sends it instead.
    /// @param sequence Wormhole sequence number of the failed action.
    function retryFailedAction(uint64 sequence) public {
        IGovernanceVoting.ProposedAction memory action = failedActions[sequence];
        require(action.target != address(0), GovReceiverNothingToRetry(sequence));

        (bool success, bytes memory returndata) = action.target.call{value: action.value}(action.data);
        require(success, GovReceiverExecutionFailed(returndata));

        delete failedActions[sequence];
        emit CrossChainActionExecuted(sequence, keccak256(abi.encode(action)));
    }

    /// @dev Executes a single action without propagating target reverts, deferring failures.
    function _executeAction(uint64 sequence, IGovernanceVoting.ProposedAction memory action) private {
        (bool success, bytes memory returndata) = action.target.call{value: action.value}(action.data);

        if (success) {
            emit CrossChainActionExecuted(sequence, keccak256(abi.encode(action)));
        } else {
            failedActions[sequence] = action;
            emit CrossChainActionFailed(sequence, keccak256(abi.encode(action)), returndata);
        }
    }

    /// @dev Executes ready queued messages in order, at most _MAX_QUEUE_DRAIN per call.
    function _drainQueue() private {
        uint64 sequence = expectedSequence;
        uint256 drained;

        while (drained < _MAX_QUEUE_DRAIN) {
            bytes memory encodedAction = queuedPayloads[sequence];
            if (encodedAction.length == 0) break;

            delete queuedPayloads[sequence];
            IGovernanceVoting.ProposedAction memory action = abi.decode(
                encodedAction,
                (IGovernanceVoting.ProposedAction)
            );
            _executeAction(sequence, action);

            unchecked {
                sequence++;
                drained++;
            }
        }

        expectedSequence = sequence;
    }
}
