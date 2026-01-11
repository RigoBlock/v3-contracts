// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {DestinationMessageParams} from "../../../types/Crosschain.sol";

/// @title EAcrossHandler Interface - Handles incoming cross-chain transfers
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IEAcrossHandler {
    error InvalidOpType();
    error DonationLock(bool locked);
    error BalanceUnderflow();
    error NavManipulationDetected(uint256 expectedNav, uint256 actualNav);
    error TokenNotInitialized();

    /// @notice Handles cross-chain message from Across SpokePool.
    /// @dev Called via delegatecall from pool when Across fills deposits. Callable by anyone.
    /// @param token The token received on this chain.
    /// @param amount The amount received.
    /// @param params The message params from the source calls sent to the across multicall handler.
    function donate(address token, uint256 amount, DestinationMessageParams calldata params) external payable;
}
