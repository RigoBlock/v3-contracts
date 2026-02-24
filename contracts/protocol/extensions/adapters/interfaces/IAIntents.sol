// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

/// @title AIntents Interface - Across Protocol integration for cross-chain transfers
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IAIntents {
    /// @notice Emitted when tokens are deposited for cross-chain transfer
    /// @param from Address that initiated the transfer
    /// @param destinationChainId Destination chain ID
    /// @param inputToken Token being sent
    /// @param inputAmount Amount sent
    /// @param opType Operation type (0=Transfer, 1=Sync)
    /// @param escrow Escrow address receiving refunds
    event CrossChainTransferInitiated(
        address indexed from,
        uint256 indexed destinationChainId,
        address indexed inputToken,
        uint256 inputAmount,
        uint8 opType,
        address escrow
    );

    error DirectCallNotAllowed();
    error NullAddress();
    error OutputAmountTooHigh();
    error TokenNotActive();
    error SameChainTransfer();
    error InvalidInputToken();

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

    /// @notice Executes a crosschain token transfer to across and updated virtual storage.
    /// @dev Has different method selector than across depositV3 to avoid viaIr compilation.
    /// @param params Across params encoded as tuple.
    function depositV3(AcrossParams memory params) external;
}
