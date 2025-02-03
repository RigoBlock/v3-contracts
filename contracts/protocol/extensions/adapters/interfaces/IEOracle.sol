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
    /// @notice Returns the token amount converted to a target token.
    /// @param token The address of the token to be converted
    /// @param amount The token amount to be converted
    /// @param targetToken The address of the target token
    /// @return value The converted amount in target token
    /// @dev Will first try to convert via crosses with chain currency, fallback to direct cross if not available.
    /// @dev Assumes token is always different from targetToken, which is the msg.sender's responsibility to verify.
    function convertTokenAmount(
        address token,
        uint256 amount,
        address targetToken
    ) external view returns (uint256 value);

    /// @notice Returns the address of the oracle hook stored in the bytecode
    /// @return The address of the oracle hook
    function getOracleAddress() external view returns (address);

    /// @notice Returns whether a token has a price feed.
    /// @param token The address of the token.
    /// @return Boolean the price feed exists.
    function hasPriceFeed(address token) external view returns (bool);

    // TODO: check return a TWAP instead of last stored tick, as price will be stored for later use
    /// @notice Returns token tick aginst native currency and flag whether the price feed exists.
    /// @param token The address of the token.
    /// @return tick The token tick.
    /// @return cardinality The max number of stored observations.
    /// @dev Positive cardinality is flag for price feed existing.
    function getTick(address token) external view returns (int24 tick, uint16 cardinality);
}
