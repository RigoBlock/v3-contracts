// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

/// @notice Mock Across MulticallHandler for testing
/// @dev Minimal mock implementation to satisfy ECrosschain constructor requirements
/// and support both foundry and hardhat test environments
contract MockAcrossMulticallHandler {
    /// @notice Mock multicall function that matches the actual Across Protocol MulticallHandler interface
    /// @dev This is a placeholder implementation for testing purposes
    function handleV3AcrossMessage(
        address /*token*/,
        uint256 /*amount*/,
        address /*originSender*/,
        bytes memory /*message*/
    ) external pure {
        // Mock implementation - just return successfully
        // In real implementation, this would route the message to the appropriate handler
        return;
    }

    /// @notice Fallback function to handle any other calls
    fallback() external payable {
        // Do nothing, just return successfully
    }

    /// @notice Receive function to handle direct ETH transfers
    receive() external payable {
        // Do nothing, just accept ETH
    }
}
