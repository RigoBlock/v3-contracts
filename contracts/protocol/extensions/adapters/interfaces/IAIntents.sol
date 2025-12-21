// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {IAcrossSpokePool} from "../../../interfaces/IAcrossSpokePool.sol";
import {OpType} from "../../../types/Crosschain.sol";

/// @title AIntents Interface - Across Protocol integration for cross-chain transfers
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IAIntents {
    /// @notice Emitted when tokens are deposited for cross-chain transfer
    /// @param pool Address of the pool initiating the transfer
    /// @param inputToken Token being sent
    /// @param outputToken Token to be received on destination
    /// @param inputAmount Amount sent
    /// @param outputAmount Expected amount to receive
    /// @param destinationChainId Destination chain ID
    event CrossChainTransferInitiated(
        address indexed pool,
        address indexed inputToken,
        address indexed outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId
    );

    error DirectCallNotAllowed();
    error NullAddress();
    error TokenNotActive();
    error InsufficientWrappedNativeBalance();
    error InvalidOpType();
    error SameChainTransfer();

    struct AcrossParams {
        address depositor;
        address recipient;
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 destinationChainId;
        address exclusiveRelayer;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
        bytes message;
    }

    // TODO: add natspec docs and lint
    function depositV3(AcrossParams memory params) external;

    /// @notice Gets the deterministic escrow address for Transfer operations
    /// @param opType The operation type (only Transfer supported)
    /// @return escrowAddress The deterministic escrow address
    function getEscrowAddress(OpType opType) external view returns (address escrowAddress);
}
