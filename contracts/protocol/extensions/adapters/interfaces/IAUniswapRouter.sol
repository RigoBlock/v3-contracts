// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

interface IAUniswapRouter {
    /// @notice Executes encoded commands along with provided inputs. Reverts if deadline has expired.
    /// @param commands A set of concatenated commands, each 1 byte in length.
    /// @param inputs An array of byte strings containing abi encoded inputs for each command.
    /// @param deadline The deadline by which the transaction must be executed.
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external;

    /// @notice Executes encoded commands along with provided inputs.
    /// @param commands A set of concatenated commands, each 1 byte in length.
    /// @param inputs An array of byte strings containing abi encoded inputs for each command.
    /// @dev Only mint call has access to state, will revert with direct calls unless recipient is explicitly set to this.
    function execute(bytes calldata commands, bytes[] calldata inputs) external;

    /// @notice Executes a Uniswap V4 Posm liquidity transaction.
    /// @param unlockData Encoded calldata containing actions to be executed.
    /// @param deadline Deadline of the transaction.
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external;
}
