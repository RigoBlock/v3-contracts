// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

/// @title EAcrossHandler Interface - Handles incoming cross-chain transfers
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IEAcrossHandler {
    error TokenWithoutPriceFeed();
    error NavDeviationTooHigh();
    error InvalidOpType();
    error UnauthorizedCaller();
    error ChainsNotSynced();

    /// @notice Handles cross-chain message from Across SpokePool
    /// @dev Called via delegatecall from pool when Across fills deposits. MUST be called by SpokePool only.
    /// @param tokenReceived The token received on this chain
    /// @param amount The amount received
    /// @param message The encoded SourceChainMessage from source chain
    function handleV3AcrossMessage(
        address tokenReceived,
        uint256 amount,
        bytes calldata message
    ) external;
}
