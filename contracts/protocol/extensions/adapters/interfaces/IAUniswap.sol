// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2022-2025 Rigo Intl.

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

import "../../../../utils/exchanges/uniswap/ISwapRouter02/ISwapRouter02.sol";

interface IAUniswap {
    /// @notice Unwraps the contract's WETH9 balance and sends it to recipient as ETH.
    /// @dev The amountMinimum parameter prevents malicious contracts from stealing WETH9 from users.
    /// @param amountMinimum The minimum amount of WETH9 to unwrap.
    function unwrapWETH9(uint256 amountMinimum) external;

    /// @notice Unwraps ETH from WETH9.
    /// @param amountMinimum The minimum amount of WETH9 to unwrap.
    /// @param recipient The address to keep same uniswap npm selector.
    function unwrapWETH9(uint256 amountMinimum, address recipient) external;

    /// @notice Wraps ETH.
    /// @dev Client must wrap if input is native currency.
    /// @param value The ETH amount to be wrapped.
    function wrapETH(uint256 value) external;
}
