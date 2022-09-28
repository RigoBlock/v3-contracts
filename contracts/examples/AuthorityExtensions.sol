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

pragma solidity 0.8.14;

import {IAuthorityCore as Authority} from "../protocol/interfaces/IAuthorityCore.sol";
import {IAuthorityExtensions} from "./IAuthorityExtensions.sol";

/// @title AuthorityExtensions - A helper contract for the Rigoblock extensions.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract AuthorityExtensions is IAuthorityExtensions {
    // TODO: simplify this contract's storage as well
    address private immutable AUTHORITY_CORE;

    GroupsList private groupsList;

    mapping(address => address) private approvedTokenOnExchange;
    mapping(address => address) private approvedTokenOnWrapper;
    mapping(address => Permission) private permission;

    enum Group {
        EXCHANGE,
        TOKEN,
        WRAPPER,
        PROXY
    }

    struct Permission {
        mapping(Group => bool) authorized;
    }

    struct GroupsList {
        address[] exchanges;
        address[] tokens;
        address[] wrappers;
        address[] proxies;
    }

    /*
     * MODIFIERS
     */
    modifier onlyWhitelister() {
        require(isWhitelister(msg.sender));
        _;
    }

    constructor(address _authorityCore) {
        AUTHORITY_CORE = _authorityCore;
    }

    /*
     * CORE FUNCTIONS
     */
    /// @dev Allows a whitelister to whitelist a token.
    /// @param _token Address of the token.
    /// @param _isWhitelisted Bool whitelisted.
    // TODO: fix following methods as _isWhitelisted not used for removing, but returned in log
    function whitelistToken(address _token, bool _isWhitelisted) external override onlyWhitelister {
        permission[_token].authorized[Group.TOKEN] = true;
        groupsList.tokens.push(_token);
        emit WhitelistedAsset(_token, _isWhitelisted);
    }

    /// @dev Allows a whitelister to whitelist an exchange
    /// @param _exchange Address of the target exchange
    /// @param _isWhitelisted Bool whitelisted
    function whitelistExchange(address _exchange, bool _isWhitelisted) external override onlyWhitelister {
        permission[_exchange].authorized[Group.EXCHANGE] = true;
        groupsList.exchanges.push(_exchange);
        emit WhitelistedExchange(_exchange, _isWhitelisted);
    }

    /// @dev Allows a whitelister to whitelist an token wrapper
    /// @param _wrapper Address of the target token wrapper
    /// @param _isWhitelisted Bool whitelisted
    function whitelistWrapper(address _wrapper, bool _isWhitelisted) external override onlyWhitelister {
        permission[_wrapper].authorized[Group.WRAPPER] = true;
        groupsList.wrappers.push(_wrapper);
        emit WhitelistedWrapper(_wrapper, _isWhitelisted);
    }

    /// @dev Allows a whitelister to whitelist a tokenTransferProxy
    /// @param _tokenTransferProxy Address of the proxy
    /// @param _isWhitelisted Bool whitelisted
    function whitelistTokenTransferProxy(address _tokenTransferProxy, bool _isWhitelisted)
        external
        override
        onlyWhitelister
    {
        permission[_tokenTransferProxy].authorized[Group.PROXY] = true;
        groupsList.proxies.push(_tokenTransferProxy);
        emit WhitelistedProxy(_tokenTransferProxy, _isWhitelisted);
    }

    /// @dev Allows a whitelister to enable trading on a particular exchange
    /// @param _token Address of the token
    /// @param _exchange Address of the exchange
    /// @param _isWhitelisted Bool whitelisted
    function whitelistTokenOnExchange(
        address _token,
        address _exchange,
        bool _isWhitelisted
    ) external override onlyWhitelister {
        approvedTokenOnExchange[_token] = _exchange;
        emit WhitelistedAsset(_token, _isWhitelisted);
    }

    /// @dev Allows a whitelister to enable assiciate wrappers to a token
    /// @param _token Address of the token
    /// @param _wrapper Address of the exchange
    /// @param _isWhitelisted Bool whitelisted
    function whitelistTokenOnWrapper(
        address _token,
        address _wrapper,
        bool _isWhitelisted
    ) external override onlyWhitelister {
        approvedTokenOnWrapper[_token] = _wrapper;
        emit WhitelistedAsset(_token, _isWhitelisted);
    }

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    /// @dev Provides whether an asset is whitelisted.
    /// @param _token Address of the target token.
    /// @return Bool is whitelisted.
    function isWhitelistedToken(address _token) external view override returns (bool) {
        return permission[_token].authorized[Group.TOKEN];
    }

    /// @dev Provides whether an exchange is whitelisted
    /// @param _exchange Address of the target exchange
    /// @return Bool is whitelisted
    function isWhitelistedExchange(address _exchange) external view override returns (bool) {
        return permission[_exchange].authorized[Group.EXCHANGE];
    }

    /// @dev Provides whether a token wrapper is whitelisted
    /// @param _wrapper Address of the target exchange
    /// @return Bool is whitelisted
    function isWhitelistedWrapper(address _wrapper) external view override returns (bool) {
        return permission[_wrapper].authorized[Group.WRAPPER];
    }

    /// @dev Provides whether a proxy is whitelisted
    /// @param _tokenTransferProxy Address of the proxy
    /// @return Bool is whitelisted
    function isWhitelistedProxy(address _tokenTransferProxy) external view override returns (bool) {
        return permission[_tokenTransferProxy].authorized[Group.PROXY];
    }

    /// @dev Checkes whether a token is allowed on an exchange
    /// @param _token Address of the token
    /// @param _exchange Address of the exchange
    /// @return Bool the token is whitelisted on the exchange
    function canTradeTokenOnExchange(address _token, address _exchange) external view override returns (bool) {
        return approvedTokenOnExchange[_token] == _exchange;
    }

    /// @dev Checkes whether a token is allowed on a wrapper
    /// @param _token Address of the token
    /// @param _wrapper Address of the token wrapper
    /// @return Bool the token is whitelisted on the exchange
    function canWrapTokenOnWrapper(address _token, address _wrapper) external view override returns (bool) {
        return approvedTokenOnWrapper[_token] == _wrapper;
    }

    /*
     * INTERNAL FUNCTIONS
     */
    /// @dev Provides whether an address is whitelister
    /// @param _target Address of the target whitelister
    /// @return Bool is whitelisted
    function isWhitelister(address _target) internal view returns (bool) {
        return Authority(AUTHORITY_CORE).isWhitelister(_target);
    }
}
