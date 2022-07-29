// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2018 RigoBlock, Rigo Investment Sagl.

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

/// @title Extensions Authority Interface - A helper contract for the Rigoblock extensions.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
interface IAuthorityExtensions {
    /*
     * EVENTS
     */
    event WhitelistedAsset(address indexed asset, bool approved);
    event WhitelistedExchange(address indexed exchange, bool approved);
    event WhitelistedWrapper(address indexed wrapper, bool approved);
    event WhitelistedProxy(address indexed proxy, bool approved);

    /*
     * CORE FUNCTIONS
     */
    /// @dev Allows a whitelister to whitelist an asset
    /// @param _token Address of the token
    /// @param _isWhitelisted Bool whitelisted
    function whitelistToken(address _token, bool _isWhitelisted) external;

    /// @dev Allows a whitelister to whitelist an exchange
    /// @param _exchange Address of the target exchange
    /// @param _isWhitelisted Bool whitelisted
    function whitelistExchange(address _exchange, bool _isWhitelisted) external;

    /// @dev Allows a whitelister to whitelist an token wrapper
    /// @param _wrapper Address of the target token wrapper
    /// @param _isWhitelisted Bool whitelisted
    function whitelistWrapper(address _wrapper, bool _isWhitelisted) external;

    /// @dev Allows a whitelister to whitelist a tokenTransferProxy
    /// @param _tokenTransferProxy Address of the proxy
    /// @param _isWhitelisted Bool whitelisted
    function whitelistTokenTransferProxy(address _tokenTransferProxy, bool _isWhitelisted) external;

    /// @dev Allows a whitelister to enable trading on a particular exchange
    /// @param _token Address of the token
    /// @param _exchange Address of the exchange
    /// @param _isWhitelisted Bool whitelisted
    function whitelistTokenOnExchange(
        address _token,
        address _exchange,
        bool _isWhitelisted
    ) external;

    /// @dev Allows a whitelister to enable assiciate wrappers to a token
    /// @param _token Address of the token
    /// @param _wrapper Address of the exchange
    /// @param _isWhitelisted Bool whitelisted
    function whitelistTokenOnWrapper(
        address _token,
        address _wrapper,
        bool _isWhitelisted
    ) external;

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    /// @dev Provides whether an asset is whitelisted.
    /// @param _token Address of the target token.
    /// @return Bool is whitelisted.
    function isWhitelistedToken(address _token) external view returns (bool);

    /// @dev Provides whether an exchange is whitelisted
    /// @param _exchange Address of the target exchange
    /// @return Bool is whitelisted
    function isWhitelistedExchange(address _exchange) external view returns (bool);

    /// @dev Provides whether a token wrapper is whitelisted
    /// @param _wrapper Address of the target exchange
    /// @return Bool is whitelisted
    function isWhitelistedWrapper(address _wrapper) external view returns (bool);

    /// @dev Provides whether a proxy is whitelisted
    /// @param _tokenTransferProxy Address of the proxy
    /// @return Bool is whitelisted
    function isWhitelistedProxy(address _tokenTransferProxy) external view returns (bool);

    /// @dev Checkes whether a token is allowed on an exchange
    /// @param _token Address of the token
    /// @param _exchange Address of the exchange
    /// @return Bool the token is whitelisted on the exchange
    function canTradeTokenOnExchange(address _token, address _exchange) external view returns (bool);

    /// @dev Checkes whether a token is allowed on a wrapper
    /// @param _token Address of the token
    /// @return Bool the token is whitelisted on the exchange
    function canWrapTokenOnWrapper(address _token, address _wrapper) external view returns (bool);
}
