// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

/// @title EAcrossHandler Interface - Handles incoming cross-chain transfers
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IEAcrossHandler {
    error TokenWithoutPriceFeed();
    error NavDeviationTooHigh();
    error InvalidMessageType();
    error UnauthorizedCaller();
    error ChainsNotSynced();

    enum MessageType {
        Transfer, // NAV offset with virtual balances on both chains
        Rebalance, // NAV changes on both chains, verify destination NAV matches source (requires prior sync)
        Sync      // Records NAV spread between chains, enables future rebalances
    }

    struct CrossChainMessage {
        MessageType messageType;
        uint256 sourceChainId; // Chain ID of the source chain
        uint256 sourceNav; // NAV per share on source chain (in base token decimals)
        uint8 sourceDecimals; // Base token decimals on source chain
        uint256 navTolerance; // Tolerance in basis points (e.g., 100 = 1%), not used in Sync mode
        bool unwrapNative; // Whether to unwrap wrapped native on destination
    }

    /// @notice Handles cross-chain message from Across SpokePool
    /// @dev Called via delegatecall from pool when Across fills deposits. MUST be called by SpokePool only.
    /// @param tokenReceived The token received on this chain
    /// @param amount The amount received
    /// @param message The encoded CrossChainMessage from source chain
    function handleV3AcrossMessage(
        address tokenReceived,
        uint256 amount,
        bytes calldata message
    ) external;
}
