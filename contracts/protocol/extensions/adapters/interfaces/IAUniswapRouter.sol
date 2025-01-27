// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2024 Rigo Intl.

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

interface IAUniswapRouter {
    struct Parameters {
        uint256 value;
        address[] recipients;
        address[] tokensIn;
        address[] tokensOut;
        int256[] tokenIds;
    }

    /// @notice Executes encoded commands along with provided inputs. Reverts if deadline has expired.
    /// @param commands A set of concatenated commands, each 1 byte in length.
    /// @param inputs An array of byte strings containing abi encoded inputs for each command.
    /// @param deadline The deadline by which the transaction must be executed.
    /// @return params The decoded relevant parameters of the call.
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external returns (Parameters memory params);

    /// @notice Executes encoded commands along with provided inputs.
    /// @param commands A set of concatenated commands, each 1 byte in length.
    /// @param inputs An array of byte strings containing abi encoded inputs for each command.
    /// @return params The decoded relevant parameters of the call.
    /// @dev Only mint call has access to state, will revert with direct calls unless recipient is explicitly set to this.
    function execute(bytes calldata commands, bytes[] calldata inputs) external returns (Parameters memory params);

    /// @notice The address of the Uniswap liquidity position manager contract.
    /// @return positionManager The address of the UniswapV4 Posm.
    function positionManager() external view returns (address positionManager);

    /// @notice The address of the Uniswap universal router contract.
    /// @return uniswapRouter The address of the Uniswap universal router.
    function uniswapRouter() external view returns (address uniswapRouter);
}
