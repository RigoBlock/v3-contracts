// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

// solhint-disable-next-line no-global-import
import "./IGovernanceVoting.sol";

/// @title IGovernanceCrosschain - Types for Wormhole cross-chain governance messages.
/// @notice This interface is no longer implemented by the governance contract.
///         It only defines the payload decoded by the target-chain CrosschainReceiver.
interface IGovernanceCrosschain {
    /// @notice Payload sent inside a Wormhole VAA to a target-chain receiver.
    /// @param targetWormholeChainId Wormhole chain id the message is intended for.
    /// @param proposalId Mainnet governance proposal id that produced the message.
    /// @param action Action to execute on the target chain.
    struct CrossChainPayload {
        uint16 targetWormholeChainId;
        uint256 proposalId;
        IGovernanceVoting.ProposedAction action;
    }

    /// @notice Emitted when a cross-chain action is executed on the target chain.
    /// @param sequence Wormhole sequence number of the consumed VAA.
    /// @param actionHash keccak256 hash of the executed action.
    event CrossChainActionExecuted(uint64 sequence, bytes32 actionHash);
}
