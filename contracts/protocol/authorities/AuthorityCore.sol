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

    mapping(address => User) private accounts;

    TypesList list;

    enum PermissionType {
        WHITELISTER,
        AUTHORITY,
        FACTORY
    }

    struct User {
        mapping(PermissionType => bool) authorized;
    }

    struct TypesList {
        address[] whitelisters;
        address[] authorities;
        address[] factories;
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
        onlyOwner
    {
        _changePermission(_authority, _isWhitelisted, PermissionType.AUTHORITY);
    }

    /// @dev Allows the owner to whitelist a whitelister.
    /// @param _whitelister Address of the whitelister.
    /// @param _isWhitelisted Bool whitelisted.
    /// @notice Whitelister permission is required to approve methods in extensions adapter.
    function setWhitelister(address _whitelister, bool _isWhitelisted)
        external
        onlyOwner
    {
        _changePermission(_whitelister, _isWhitelisted, PermissionType.WHITELISTER);
    }

    // TODO: in registry we could require approved factory or authority, to simplify here and be more explicit
    /// @dev Allows an admin to whitelist a factory.
    /// @param _factory Address of the target factory.
    /// @param _isWhitelisted Bool whitelisted.
    function whitelistFactory(address _factory, bool _isWhitelisted)
        external
        onlyOwner
    {
        _changePermission(_factory, _isWhitelisted, PermissionType.FACTORY);
    }

    /// @dev Allows the owner to set the extensions authority.
    /// @param _extensionsAuthority Address of the extensions authority.
    function setExtensionsAuthority(address _extensionsAuthority)
        external
        onlyOwner
    {
        extensionsAuthority = _extensionsAuthority;
        emit NewExtensionsAuthority(extensionsAuthority);
    }

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */

    /// @dev Provides whether an address is an authority.
    /// @param _authority Address of the target authority.
    /// @return Bool is whitelisted.
    function isAuthority(address _authority)
        external view
        returns (bool)
    {
        return accounts[_authority].authorized[PermissionType.AUTHORITY];
    }

    /// @dev Provides whether a factory is whitelisted.
    /// @param _factory Address of the target factory.
    /// @return Bool is whitelisted.
    function isWhitelistedFactory(address _factory)
        external view
        returns (bool)
    {
        return accounts[_factory].authorized[PermissionType.FACTORY];
    }

    /// @dev Provides the address of the exchanges authority.
    /// @return Address of the adapter.
    function getAuthorityExtensions()
        external view
        returns (address)
    {
        return extensionsAuthority;
    }

    /*
     * INTERNAL FUNCTIONS
     */
    // TODO: if not using whitelisters, remove. We are using in extensions auth but here is defined internal.
    /// @dev Provides whether an address is whitelister.
    /// @param _whitelister Address of the target whitelister.
    /// @return Bool is whitelisted.
    function isWhitelister(address _whitelister)
        internal view
        returns (bool)
    {
        return accounts[_whitelister].authorized[PermissionType.WHITELISTER];
    }

    function _changePermission(
        address _target,
        bool _isWhitelisted,
        PermissionType _permissionType
    )
        private
    {
        if (_isWhitelisted) {
            require(!accounts[_target].authorized[_permissionType], "ALREADY_WHITELISTED_ERROR");
            accounts[_target].authorized[_permissionType] = _isWhitelisted;

            if (_permissionType == PermissionType.AUTHORITY) {
                list.authorities.push(_target);
                emit AuthoritySet(_target);
            } else if (_permissionType == PermissionType.FACTORY) {
                list.factories.push(_target);
                emit WhitelistedFactory(_target);
            } else {
                list.whitelisters.push(_target);
                emit WhitelisterSet(_target);
            }
        } else {
            require(accounts[_target].authorized[_permissionType], "NOT_AUTHORIZED");
            delete accounts[_target].authorized[_permissionType];

            for (uint i = 0; i < list.authorities.length; i++) {
                if (list.authorities[i] == _target) {
                    if (_permissionType == PermissionType.AUTHORITY) {
                        list.authorities[i] = list.authorities[list.authorities.length - 1];
                        list.authorities.pop();
                        emit RemovedAuthority(_target);
                    } else if (_permissionType == PermissionType.FACTORY) {
                        list.factories[i] = list.factories[list.factories.length - 1];
                        list.factories.pop();
                        emit RemovedFactory(_target);
                    } else {
                        list.whitelisters[i] = list.whitelisters[list.whitelisters.length - 1];
                        list.whitelisters.pop();
                        emit RemovedWhitelister(_target);
                    }

                    break;
                }
            }
        }
    }
}
