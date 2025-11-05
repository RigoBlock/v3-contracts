// SPDX-License-Identifier: Apache-2.0-or-later
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

pragma solidity 0.8.28;

interface IDeflation {
    /// @notice Allows anyone to convert a token to GRG at a reverse-dutch-auction discount.
    /// @dev Calling this method will reset the discount to 0.
    /// @param tokenOut The address of the desired token.
    /// @param amountOut The desired amount.
    /// @return amountIn The amount of GRG required to buy the desired amount.
    function buyToken(address tokenOut, uint256 amountOut) external returns (uint256 amountIn);

    /// @notice Returns the current discount for a given token.
    /// @param token The address of the target token.
    /// @return The current discount in basis points.
    function getCurrentDiscount(address token) external view returns (uint256);
}