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

import {OwnedUninitialized as Owned} from "../../utils/owned/OwnedUninitialized.sol";
import {IAuthorityCore} from "../interfaces/IAuthorityCore.sol";

/// @title AuthorityCore - Allows to set up the base rules of the protocol.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract AuthorityCore is Owned, IAuthorityCore {
    /// @inheritdoc IAuthorityCore
    address public override extensionsAuthority;

    mapping(bytes4 => address) private adapterBySelector;
    mapping(address => Permission) private permission;
    mapping(Role => address[]) private roleToList;

    modifier onlyWhitelister {
        require(isWhitelister(msg.sender), "AUTHORITY_SENDER_NOT_WHITELISTER_ERROR");
        _;
    }

    constructor(address _owner) {
        owner = _owner;
    }

    /*
     * CORE FUNCTIONS
     */
    /// @inheritdoc IAuthorityCore
    function addMethod(bytes4 _selector, address _adapter) external override onlyWhitelister {
        require(permission[_adapter].authorized[Role.ADAPTER], "ADAPTER_NOT_WHITELISTED_ERROR");
        require(adapterBySelector[_selector] == address(0), "SELECTOR_EXISTS_ERROR");
        adapterBySelector[_selector] = _adapter;
        emit WhitelistedMethod(msg.sender, _adapter, _selector);
    }

    /// @inheritdoc IAuthorityCore
    function removeMethod(bytes4 _selector, address _adapter) external override onlyWhitelister {
        require(adapterBySelector[_selector] != address(0), "AUTHORITY_METHOD_NOT_APPROVED_ERROR");
        delete adapterBySelector[_selector];
        emit RemovedMethod(msg.sender, _adapter, _selector);
    }

    /// @inheritdoc IAuthorityCore
    function setExtensionsAuthority(address _extensionsAuthority) external override onlyOwner {
        extensionsAuthority = _extensionsAuthority;
        emit NewExtensionsAuthority(extensionsAuthority);
    }

    /// @inheritdoc IAuthorityCore
    function setWhitelister(address _whitelister, bool _isWhitelisted) external override onlyOwner {
        _changePermission(_whitelister, _isWhitelisted, Role.WHITELISTER);
    }

    /// @inheritdoc IAuthorityCore
    function setAdapter(address _adapter, bool _isWhitelisted) external override onlyOwner {
        _changePermission(_adapter, _isWhitelisted, Role.ADAPTER);
    }

    /// @inheritdoc IAuthorityCore
    function setFactory(address _factory, bool _isWhitelisted) external override onlyOwner {
        _changePermission(_factory, _isWhitelisted, Role.FACTORY);
    }

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    /// @inheritdoc IAuthorityCore
    function isWhitelistedFactory(address _target) external view override returns (bool) {
        return permission[_target].authorized[Role.FACTORY];
    }

    function getApplicationAdapter(bytes4 _selector) external view override returns (address) {
        return adapterBySelector[_selector];
    }

    /// @inheritdoc IAuthorityCore
    function getAuthorityExtensions() external view override returns (address) {
        return extensionsAuthority;
    }

    /// @inheritdoc IAuthorityCore
    function isWhitelister(address _target) public view override returns (bool) {
        return permission[_target].authorized[Role.WHITELISTER];
    }

    /*
     * INTERNAL FUNCTIONS
     */
    function _changePermission(
        address _target,
        bool _isWhitelisted,
        Role _role
    ) private {
        require(_target != address(0), "AUTHORITY_TARGET_NULL_ADDRESS_ERROR");
        if (_isWhitelisted) {
            require(!permission[_target].authorized[_role], "ALREADY_WHITELISTED_ERROR");
            permission[_target].authorized[_role] = _isWhitelisted;
            roleToList[_role].push(_target);
            emit PermissionAdded(msg.sender, _target, uint8(_role));
        } else {
            require(permission[_target].authorized[_role], "NOT_ALREADY_WHITELISTED");
            delete permission[_target].authorized[_role];
            uint256 length = roleToList[_role].length;
            for (uint256 i = 0; i < length; i++) {
                if (roleToList[_role][i] == _target) {
                    roleToList[_role][i] = roleToList[_role][length - 1];
                    roleToList[_role].pop();
                    emit PermissionRemoved(msg.sender, _target, uint8(_role));

                    break;
                }
            }
        }
    }
}
