// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6;

/// @title ICoreDepositWallet
/// @notice Minimal interface for the Circle CoreDepositWallet on HyperEVM.
interface ICoreDepositWallet {
    /// @notice Deposits tokens for the sender into HyperCore.
    /// @param amount The amount of tokens being deposited.
    /// @param destinationDex The destination dex on HyperCore.
    function deposit(uint256 amount, uint32 destinationDex) external;
}
