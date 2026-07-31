// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6;

/// @title ICoreWriter
/// @notice Minimal interface for the Hyperliquid CoreWriter contract.
interface ICoreWriter {
    /// @notice Submits a raw HyperCore action.
    function sendRawAction(bytes calldata data) external;
}
