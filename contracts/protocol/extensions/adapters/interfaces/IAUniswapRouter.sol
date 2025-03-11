// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2025 Rigo Intl.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.

*/

pragma solidity >=0.8.0 <0.9.0;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

interface IAUniswapRouter {
    /// @notice Executes encoded commands along with provided inputs. Reverts if deadline has expired.
    /// @param commands A set of concatenated commands, each 1 byte in length.
    /// @param inputs An array of byte strings containing abi encoded inputs for each command.
    /// @param deadline The deadline by which the transaction must be executed.
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external;

    /// @notice Executes encoded commands along with provided inputs.
    /// @param commands A set of concatenated commands, each 1 byte in length.
    /// @param inputs An array of byte strings containing abi encoded inputs for each command.
    /// @dev Only mint call has access to state, will revert with direct calls unless recipient is explicitly set to this.
    function execute(bytes calldata commands, bytes[] calldata inputs) external;

    /// @notice Executes a Uniswap V4 Posm liquidity transaction.
    /// @param unlockData Encoded calldata containing actions to be executed.
    /// @param deadline Deadline of the transaction.
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external;

    /// @notice The Uniswap V4 liquidity position manager contract.
    /// @return The address of the UniswapV4 Posm.
    function uniV4Posm() external view returns (IPositionManager);

    /// @notice The address of the Uniswap universal router contract.
    /// @return uniswapRouter The address of the Uniswap universal router.
    function uniswapRouter() external view returns (address uniswapRouter);
}
