// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2022 Rigo Intl.

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

/// @title EWhitelist Interface - Allows interaction with the whitelist extension contract.
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IEWhitelist {
    /// @notice Emitted when a token is whitelisted or removed.
    /// @param token Address pf the target token.
    /// @param isWhitelisted Boolean the token is added or removed.
    event Whitelisted(address indexed token, bool isWhitelisted);

    /// @notice Allows a whitelister to whitelist a token.
    /// @param _token Address of the target token.
    function whitelistToken(address _token) external;

    /// @notice Allows a whitelister to remove a token.
    /// @param _token Address of the target token.
    function removeToken(address _token) external;

    /// @notice Allows a whitelister to whitelist/remove a list of tokens.
    /// @param _tokens Address array to tokens.
    /// @param _whitelisted Bollean array the token is to be whitelisted or removed.
    function batchUpdateTokens(address[] calldata _tokens, bool[] memory _whitelisted) external;

    /// @notice Returns whether a token has been whitelisted.
    /// @param _token Address of the target token.
    /// @return Boolean the token is whitelisted.
    function isWhitelistedToken(address _token) external view returns (bool);

    /// @notice Returns the address of the authority contract.
    /// @return Address of the authority contract.
    function getAuthority() external view returns (address);
}
