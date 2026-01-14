// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {DestinationMessageParams} from "../../../types/Crosschain.sol";

/// @title ECrosschain Interface - Handles incoming cross-chain transfers and refunds from expired deposits.
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IECrosschain {
    /// @notice Emitted when cross-chain tokens are received
    /// @param pool Address of the pool receiving tokens
    /// @param token Token received
    /// @param amount Amount received (actual balance delta)
    /// @param opType Operation type (0=Transfer, 1=Sync)
    event TokensReceived(address indexed pool, address indexed token, uint256 amount, uint8 indexed opType);

    /// @notice Emitted when virtual balance is modified
    /// @param token Token whose virtual balance changed
    /// @param adjustment Signed adjustment (+/-)
    /// @param newBalance New virtual balance after adjustment
    event VirtualBalanceUpdated(address indexed token, int256 adjustment, int256 newBalance);

    /// @notice Emitted when virtual supply is modified
    /// @param adjustment Signed adjustment (+/-)
    /// @param newSupply New virtual supply after adjustment
    event VirtualSupplyUpdated(int256 adjustment, int256 newSupply);

    error InvalidOpType();
    error DonationLock(bool locked);
    error BalanceUnderflow();
    error NavManipulationDetected(uint256 expectedNav, uint256 actualNav);
    error TokenNotInitialized();

    /// @notice Handles receiving tokens from a cross-chain message or an escrow refund.
    /// @dev Called via delegatecall from pool. Callable by anyone.
    /// @param token The token received on this chain.
    /// @param amount The amount received.
    /// @param params The message params from the source calls sent to the across multicall handler.
    function donate(address token, uint256 amount, DestinationMessageParams calldata params) external payable;
}
