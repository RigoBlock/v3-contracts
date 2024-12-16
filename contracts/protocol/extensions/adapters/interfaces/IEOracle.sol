// SPDX-License-Identifier: Apache-2.0
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

interface IEOracle {
    /// @notice Returns the token amount converted to base token.
    /// @param token The address of the token to be converted
    /// @param amount The token amount to be converted
    /// @param baseToken The address of the base token
    /// @return value The converted amount in base token
    /// @dev Will first try to convert via crosses with chain currency, fallback to direct cross if not available.
    /// @dev Assumes token is always different from baseToken. it is the msg.sender's responsibility to verify that.
    function getBaseTokenValue(address token, uint256 amount, address baseToken)
        external
        view
        returns (uint256 value)

    /// @notice Returns the address of the oracle hook stored in the bytecode
    /// @return oracleAddress The address of the oracle hook
    function getOracleAddress() external view returns (address);
}
