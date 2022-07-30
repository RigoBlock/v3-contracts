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

pragma solidity >=0.7.0 <0.9.0;

/// @title Authority Interface - Allows interaction with the Authority contract.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
interface IAuthorityCore {
    event NewExtensionsAuthority(address indexed extensionsAuthority);

    event PermissionAdded(address indexed from, address indexed target, uint8 indexed permissionType);

    event PermissionRemoved(address indexed from, address indexed target, uint8 indexed permissionType);

    event RemovedMethod(address indexed from, address indexed adapter, bytes4 indexed selector);

    event WhitelistedMethod(address indexed from, address indexed adapter, bytes4 indexed selector);

    enum Role {ADAPTER, FACTORY, WHITELISTER}

    struct Permission {
        mapping(Role => bool) authorized;
    }

    /// @dev Returns the address of the extensions authority.
    /// @return Address of the extensions authority.
    function extensionsAuthority() external view returns (address);

    /// @dev Allows a whitelister to whitelist a method.
    /// @param _selector Bytes4 hex of the method selector.
    /// @param _adapter Address of the adapter implementing the method.
    /// @notice We do not save list of approved as better queried by events.
    function addMethod(bytes4 _selector, address _adapter) external;

    /// @dev Allows a whitelister to remove a method.
    /// @param _selector Bytes4 hex of the method selector.
    /// @param _adapter Address of the adapter implementing the method.
    function removeMethod(bytes4 _selector, address _adapter) external;

    /// @dev Allows owner to set extension adapter address.
    /// @param _adapter Address of the target adapter.
    /// @param _isWhitelisted Bool whitelisted.
    function setAdapter(address _adapter, bool _isWhitelisted) external;

    /// @dev Allows the owner to set the extensions authority.
    /// @param _extensionsAuthority Address of the extensions authority.
    function setExtensionsAuthority(address _extensionsAuthority) external;

    /// @dev Allows an admin to set factory permission.
    /// @param _factory Address of the target factory.
    /// @param _isWhitelisted Bool whitelisted.
    function setFactory(address _factory, bool _isWhitelisted) external;

    /// @dev Allows the owner to set whitelister permission.
    /// @param _whitelister Address of the whitelister.
    /// @param _isWhitelisted Bool whitelisted.
    /// @notice Whitelister permission is required to approve methods in extensions adapter.
    function setWhitelister(address _whitelister, bool _isWhitelisted) external;

    /// @dev Returns the address of the adapter associated to the signature.
    /// @param _selector Hex of the method signature.
    /// @return Address of the adapter.
    function getApplicationAdapter(bytes4 _selector) external view returns (address);

    /// @dev Provides the address of the exchanges authority.
    /// @return Address of the adapter.
    function getAuthorityExtensions() external view returns (address);

    /// @dev Provides whether a factory is whitelisted.
    /// @param _target Address of the target factory.
    /// @return Bool is whitelisted.
    function isWhitelistedFactory(address _target) external view returns (bool);

    /// @dev Provides whether an address is whitelister.
    /// @param _target Address of the target whitelister.
    /// @return Bool is whitelisted.
    function isWhitelister(address _target) external view returns (bool);
}
