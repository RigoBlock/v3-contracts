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

pragma solidity >=0.8.0 <0.9.0;

interface IEOracle {
    /// @notice Returns the sum of the token amounts converted to a target token.
    /// @dev Will first try to convert via cross with chain currency, fallback to direct cross if not available.
    /// @param tokens The array of token addresses to be converted.
    /// @param amounts The array of amounts to be converted.
    /// @param targetToken The address of the target token.
    /// @return totalConvertedAmount The total value of converted amount in target token amount.
    function convertBatchTokenAmounts(
        address[] calldata tokens,
        int256[] calldata amounts,
        address targetToken
    ) external view returns (int256 totalConvertedAmount);

    /// @notice Returns a token amount converted to a target token.
    /// @dev Will first try to convert via cross with chain currency, fallback to direct cross if not available.
    /// @param token The address of the token to be converted.
    /// @param amount The amount to be converted.
    /// @param targetToken The address of the target token.
    /// @return convertedAmount The value of converted amount in target token amount.
    function convertTokenAmount(
        address token,
        int256 amount,
        address targetToken
    ) external view returns (int256 convertedAmount);

    /// @notice Returns whether a token has a price feed.
    /// @param token The address of the token.
    /// @return Boolean the price feed exists.
    function hasPriceFeed(address token) external view returns (bool);

    /// @notice Returns token price aginst native currency.
    /// @param token The address of the token.
    /// @return twap The time weighted average price.
    function getTwap(address token) external view returns (int24 twap);
}
