// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2017-2018 RigoBlock, Rigo Investment Sagl.

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

import { OwnedUninitialized as Owned } from "../../utils/owned/OwnedUninitialized.sol";
import { IAuthorityCore } from "../interfaces/IAuthorityCore.sol";

/// @title AuthorityCore - Allows to set up the base rules of the protocol.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract AuthorityCore is
    Owned,
    IAuthorityCore
{
    address public extensionsAuthority;

    mapping(bytes4 => address) private adapterBySelector;
    mapping(address => Permission) private permission;

    TypesList private list;

    enum Role {
        ADAPTER,
        AUTHORITY,
        FACTORY,
        WHITELISTER
    }

    struct Permission {
        mapping(Role => bool) authorized;
    }

    struct TypesList {
        address[] adapters;
        address[] authorities;
        address[] factories;
        address[] whitelisters;
    }

    modifier onlyWhitelister {
        require(
            isWhitelister(msg.sender),
            "AUTHORITY_SENDER_NOT_WHITELISTER_ERROR"
        );
        _;
    }

    constructor(address _owner) {
      owner = _owner;
    }

    /*
     * CORE FUNCTIONS
     */
    /// @dev Allows the owner to whitelist an authority.
    /// @param _authority Address of the authority.
    /// @param _isWhitelisted Bool whitelisted.
    function setAuthority(address _authority, bool _isWhitelisted)
        external
        override
        onlyOwner
    {
        _changePermission(_authority, _isWhitelisted, Role.AUTHORITY);
    }

    /// @dev Allows the owner to whitelist a whitelister.
    /// @param _whitelister Address of the whitelister.
    /// @param _isWhitelisted Bool whitelisted.
    /// @notice Whitelister permission is required to approve methods in extensions adapter.
    function setWhitelister(address _whitelister, bool _isWhitelisted)
        external
        override
        onlyOwner
    {
        _changePermission(_whitelister, _isWhitelisted, Role.WHITELISTER);
    }

    /// @dev Allows an admin to whitelist a factory.
    /// @param _factory Address of the target factory.
    /// @param _isWhitelisted Bool whitelisted.
    function whitelistFactory(address _factory, bool _isWhitelisted)
        external
        override
        onlyOwner
    {
        _changePermission(_factory, _isWhitelisted, Role.FACTORY);
    }

    /// @notice Allows owner to whitelist methods.
    function whitelistAdapter(address _adapter, bool _isWhitelisted)
        external
        override
        onlyOwner
    {
        _changePermission(_adapter, _isWhitelisted, Role.ADAPTER);
    }

    /// @dev Allows an admin to whitelist a factory.
    /// @param _selector Bytes4 hex of the method interface.
    /// @notice setting _adapter to address(0) will effectively revoke method.
    // TODO: must removeMethod(selector, adapter)
    function whitelistMethod(
        bytes4 _selector,
        address _adapter
    )
        external
        override
        onlyWhitelister
    {
        require(
            permission[_adapter].authorized[Role.ADAPTER],
            "ADAPTER_NOT_WHITELISTED_ERROR"
        );
        require(
            adapterBySelector[_selector] == address(0),
            "SELECTOR_EXISTS_ERROR"
        );
        adapterBySelector[_selector] = _adapter;
        emit WhitelistedMethod(_selector, _adapter);
    }

    /// @dev Allows the owner to set the extensions authority.
    /// @param _extensionsAuthority Address of the extensions authority.
    function setExtensionsAuthority(address _extensionsAuthority)
        external
        override
        onlyOwner
    {
        extensionsAuthority = _extensionsAuthority;
        emit NewExtensionsAuthority(extensionsAuthority);
    }

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */

    /// @dev Provides whether an address is an authority.
    /// @param _target Address of the target authority.
    /// @return Bool is whitelisted.
    function isAuthority(address _target)
        external
        view
        override
        returns (bool)
    {
        return permission[_target].authorized[Role.AUTHORITY];
    }

    /// @dev Provides whether a factory is whitelisted.
    /// @param _target Address of the target factory.
    /// @return Bool is whitelisted.
    function isWhitelistedFactory(address _target)
        external
        view
        override
        returns (bool)
    {
        return permission[_target].authorized[Role.FACTORY];
    }

    function getApplicationAdapter(bytes4 _selector)
        external
        view
        override
        returns (address)
    {
            return adapterBySelector[_selector];
    }

    /// @dev Provides the address of the exchanges authority.
    /// @return Address of the adapter.
    function getAuthorityExtensions()
        external 
        view
        override
        returns (address)
    {
        return extensionsAuthority;
    }

    /// @dev Provides whether an address is whitelister.
    /// @param _target Address of the target whitelister.
    /// @return Bool is whitelisted.
    function isWhitelister(address _target)
        public
        view
        override
        returns (bool)
    {
        return permission[_target].authorized[Role.WHITELISTER];
    }

    /*
     * INTERNAL FUNCTIONS
     */
    function _changePermission(
        address _target,
        bool _isWhitelisted,
        Role _role
    )
        private
    {
        if (_isWhitelisted) {
            require(!permission[_target].authorized[_role], "ALREADY_WHITELISTED_ERROR");
            permission[_target].authorized[_role] = _isWhitelisted;

            if (_role == Role.AUTHORITY) {
                list.authorities.push(_target);
                emit AuthoritySet(_target);
            } else if (_role == Role.FACTORY) {
                list.factories.push(_target);
                emit WhitelistedFactory(_target);
            } else if (_role == Role.WHITELISTER) {
                list.whitelisters.push(_target);
                emit WhitelisterSet(_target);
            } else { // remaining role is "ADAPTER"
                list.adapters.push(_target);
                emit WhitelistedAdapter(_target);
            }
        } else {
            require(permission[_target].authorized[_role], "NOT_AUTHORIZED");
            delete permission[_target].authorized[_role];

            for (uint i = 0; i < list.authorities.length; i++) {
                if (list.authorities[i] == _target) {
                    if (_role == Role.AUTHORITY) {
                        list.authorities[i] = list.authorities[list.authorities.length - 1];
                        list.authorities.pop();
                        emit RemovedAuthority(_target);
                    } else if (_role == Role.FACTORY) {
                        list.factories[i] = list.factories[list.factories.length - 1];
                        list.factories.pop();
                        emit RemovedFactory(_target);
                    } else if (_role == Role.WHITELISTER) {
                        list.whitelisters[i] = list.whitelisters[list.whitelisters.length - 1];
                        list.whitelisters.pop();
                        emit RemovedWhitelister(_target);
                    } else { // remaining role is "ADAPTER"
                        list.adapters[i] = list.adapters[list.adapters.length - 1];
                        list.adapters.pop();
                        emit RemovedAdapter(_target);
                    }

                    break;
                }
            }
        }
    }
}
