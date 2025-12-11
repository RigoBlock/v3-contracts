// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

/// @title Across Protocol SpokePool Interface
/// @notice Interface for Across Protocol V3 SpokePool contract
/// @dev Used for cross-chain token transfers via Across Protocol
interface IAcrossSpokePool {
    /// @notice Gets the wrapped native token address for this chain
    /// @return Address of the wrapped native token (e.g., WETH)
    function wrappedNativeToken() external view returns (address);
    
    /// @notice Deposits tokens to be bridged cross-chain via Across Protocol V3
    /// @param depositor Address initiating the deposit
    /// @param recipient Address receiving tokens on destination chain
    /// @param inputToken Token being deposited on source chain
    /// @param outputToken Token to be received on destination chain
    /// @param inputAmount Amount of inputToken to deposit
    /// @param outputAmount Expected amount of outputToken on destination
    /// @param destinationChainId Chain ID where tokens should be sent
    /// @param exclusiveRelayer Address of exclusive relayer (address(0) for any)
    /// @param quoteTimestamp Timestamp of the quote used for this deposit
    /// @param fillDeadline Deadline by which the deposit must be filled
    /// @param exclusivityDeadline Deadline for exclusive relayer period
    /// @param message Arbitrary data to pass to recipient
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
        bytes calldata message
    ) external payable;

    /// @notice Speeds up a pending deposit by updating output amount
    /// @dev Used to incentivize faster fills or recover funds
    /// @param depositor Original depositor address
    /// @param depositId ID of the deposit to speed up
    /// @param updatedOutputAmount New output amount (can be lower to cancel)
    /// @param updatedRecipient New recipient address
    /// @param updatedMessage New message data
    /// @param depositorSignature Signature from depositor authorizing the update
    function speedUpV3Deposit(
        address depositor,
        uint32 depositId,
        uint256 updatedOutputAmount,
        address updatedRecipient,
        bytes calldata updatedMessage,
        bytes calldata depositorSignature
    ) external;
}
