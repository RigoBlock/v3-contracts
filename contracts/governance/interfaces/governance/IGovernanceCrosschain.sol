// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

import {IGovernanceVoting} from "./IGovernanceVoting.sol";

/// @title Cross-chain governance receiver interface.
interface IGovernanceCrosschain {
    /// @notice Thrown when the Wormhole core contract reports an invalid VAA.
    error GovReceiverInvalidVaa(string reason);

    /// @notice Thrown when the VAA emitter is not the trusted sender-chain governance proxy.
    error GovReceiverUnknownEmitter();

    /// @notice Thrown when the VAA is intended for a different target chain.
    error GovReceiverWrongChain(uint16 targetChainId, uint16 localChainId);

    /// @notice Thrown when the receiver would accept messages from its own chain.
    error GovReceiverLocalEmitter(uint16 chainId);

    /// @notice Thrown when the VAA sequence is lower than the next minimum sequence.
    error GovReceiverInvalidSequence(uint64 sequence, uint64 nextMinimumSequence);

    /// @notice Thrown when the VAA is older than the execution window.
    error GovReceiverMessageExpired(uint64 sequence);

    /// @notice Thrown when the governance strategy has no Wormhole address configured.
    error GovReceiverNotConfigured();

    /// @notice Consumes a Wormhole VAA and executes the governance actions it contains.
    /// @dev Sequences must be strictly monotonically increasing but need not be consecutive:
    ///      a message that reverts is never consumed and can be skipped by delivering any
    ///      later message. A failing action reverts the whole message with the target's
    ///      return data.
    /// @param encodedMessage The raw verified VAA bytes.
    function receiveMessage(bytes memory encodedMessage) external;

    /// @notice Minimum Wormhole sequence accepted by the next `receiveMessage` call.
    function nextMinimumSequence() external view returns (uint64);
}
