// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {IAcrossSpokePool} from "../../../interfaces/IAcrossSpokePool.sol";

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
    error TokenIsNotOwned();
    error InsufficientWrappedNativeBalance();

    /// @notice Initiates a cross-chain token transfer via Across Protocol V3
    /// @dev Matches Across's depositV3 signature exactly for seamless integration
    /// @param depositor Address of the depositor (ignored, uses address(this))
    /// @param recipient Address of recipient on destination chain (ignored, uses address(this))
    /// @param inputToken Address of input token on source chain
    /// @param outputToken Address of output token on destination chain
    /// @param inputAmount Amount of input token to deposit
    /// @param outputAmount Expected amount of output token on destination
    /// @param destinationChainId Chain ID of destination
    /// @param exclusiveRelayer Address of exclusive relayer (ignored, uses address(0))
    /// @param quoteTimestamp Timestamp of the quote (ignored, uses block.timestamp)
    /// @param fillDeadline Deadline for the fill
    /// @param exclusivityDeadline Deadline for exclusive relayer (ignored, uses 0)
    /// @param message Encoded CrossChainMessage struct
    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes memory message
    ) external payable;

    /// @notice Returns the Across SpokePool address for this chain
    /// @return Address of the Across SpokePool contract
    function acrossSpokePool() external view returns (IAcrossSpokePool);
}
