// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

import {IGovernanceVoting} from "./IGovernanceVoting.sol";

/// @title Cross-chain governance receiver interface.
/// @notice Implemented by the Rigoblock governance on chains that execute actions decided by the
///         governance deployed on the sender chain. Messages are delivered through Wormhole by any
///         relayer; the trusted emitter is the governance proxy on the sender chain.
/// @dev The Wormhole configuration is read from the governance strategy, so receiver capability is
///      enabled by pointing the governance at a Wormhole-enabled strategy and can only be changed
///      through a governance proposal. See docs/wormhole/GOVERNANCE_CROSSCHAIN.md.
interface IGovernanceCrosschain {
    /// @notice Emitted when a cross-chain action is executed on this chain.
    /// @param sequence Wormhole sequence number of the consumed VAA.
    /// @param actionHash keccak256 hash of the executed action.
    event CrossChainActionExecuted(uint64 sequence, bytes32 actionHash);

    /// @notice Emitted when a cross-chain action reverts on execution and is deferred for retry.
    /// @param sequence Wormhole sequence number of the consumed VAA.
    /// @param actionHash keccak256 hash of the failed action.
    /// @param reason Revert payload returned by the target.
    event CrossChainActionFailed(uint64 sequence, bytes32 actionHash, bytes reason);

    /// @notice Thrown when the Wormhole core contract reports an invalid VAA.
    error GovReceiverInvalidVaa(string reason);

    /// @notice Thrown when the VAA emitter is not the trusted sender-chain governance proxy.
    error GovReceiverUnknownEmitter();

    /// @notice Thrown when a VAA has already been consumed.
    error GovReceiverAlreadyConsumed(bytes32 vaaHash);

    /// @notice Thrown when the VAA is intended for a different target chain.
    error GovReceiverWrongChain(uint16 targetChainId, uint16 localChainId);

    /// @notice Thrown when the receiver would accept messages from its own chain.
    error GovReceiverLocalEmitter(uint16 chainId);

    /// @notice Thrown when the VAA sequence is lower than the expected next sequence.
    error GovReceiverSequenceTooOld(uint64 sequence, uint64 expectedSequence);

    /// @notice Thrown when the target action reverts during a retry attempt.
    error GovReceiverExecutionFailed(bytes reason);

    /// @notice Thrown when retrying a sequence that has no failed action.
    error GovReceiverNothingToRetry(uint64 sequence);

    /// @notice Thrown when the governance strategy has no Wormhole address configured.
    error GovReceiverNotConfigured();

    /// @notice Consumes a Wormhole VAA and executes the governance action it contains.
    /// @dev Messages are executed in Wormhole sequence order; out-of-order messages are queued
    ///      and drained by later deliveries. A reverting action is deferred to failedActions
    ///      instead of reverting the delivery, so a single failing action can never brick the pipeline.
    /// @param encodedMessage The raw verified VAA bytes.
    function receiveMessage(bytes memory encodedMessage) external;

    /// @notice Re-executes an action that previously reverted on execution.
    /// @dev Callable by anyone once the action's preconditions on this chain are satisfied.
    /// @param sequence Wormhole sequence number of the failed action.
    function retryFailedAction(uint64 sequence) external;

    /// @notice Next Wormhole sequence expected to be executed.
    function expectedSequence() external view returns (uint64);

    /// @notice Verified VAA hashes that have already been executed.
    function consumed(bytes32 vaaHash) external view returns (bool);

    /// @notice Out-of-order messages queued by Wormhole sequence until their predecessors arrive.
    function queuedPayloads(uint64 sequence) external view returns (bytes memory);

    /// @notice Actions that reverted on execution, re-executable via retryFailedAction.
    function failedActions(uint64 sequence) external view returns (IGovernanceVoting.ProposedAction memory);
}
