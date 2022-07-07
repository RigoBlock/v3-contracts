// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2017-2022 RigoBlock, Rigo Investment Sagl.

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
import { LibSanitize } from "../../utils/LibSanitize/LibSanitize.sol";
import { IAuthorityCore as Authority } from "../interfaces/IAuthorityCore.sol";

import { IPoolRegistry } from "../interfaces/IPoolRegistry.sol";

/// @title Pool Registry - Allows registration of pools.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract PoolRegistry is IPoolRegistry, Owned {

    using LibSanitize for string;

    // TODO: if id changes, staking system will not be able to query. We should use creation salt as poolid
    //   which is same regardless of registration ordering. Before deploying, must make sure we can query pool rewards.
    // TODO: check if public AUTHORITY is useful information or can be made private
    address public immutable AUTHORITY;
    // TODO: we can probably eliminate following as unused
    string public constant VERSION = '2.0.0';

    address[] private groups;

    mapping (address => bytes32) private mapFromAddress;
    mapping (bytes32 => bytes32) private mapFromName;
    mapping (bytes32 => Pool) private poolById;
    mapping (bytes32 => PoolMeta) private poolMetaById;

    struct Pool {
        address poolAddress;
        address group;
        bytes32 name;
    }

    struct PoolMeta {
        mapping (bytes32 => bytes32) meta;
    }

    /*
     * MODIFIERS
     */
    modifier whenAddressFree(address _poolAddress) {
        require(
            mapFromAddress[_poolAddress] == 0,
            "REGISTRY_ADDRESS_ALREADY_TAKEN_ERROR"
        );
        _;
    }

    modifier onlyPoolOwner(uint256 _id) {
        (address poolAddress, , ) = fromId(_id);
        require(
            Owned(poolAddress).owner() == msg.sender,
            "REGISTRY_CALLER_IS_NOT_POOL_OWNER_ERROR"
        );
        _;
    }

    modifier whenNameLengthCorrect(string memory _input) {
        // we always want to keep name lenght below 32, for logging bytes32.
        require(
            bytes(_input).length >= 4 && bytes(_input).length <= 32,
            "REGISTRY_NAME_LENGTH_ERROR"
        );
        _;
    }

    modifier whenSymbolLengthCorrect(string memory _input) {
        require(
            bytes(_input).length >= 3 && bytes(_input).length <= 5,
            "REGISTRY_SYMBOL_LENGTH_ERROR"
        );
        _;
    }

    modifier onlyAuthority {
        require(
            Authority(AUTHORITY).isAuthority(msg.sender) == true,
            "REGISTRY_CALLER_IS_NOT_AUTHORITY_ERROR"
        );
        _;
    }

    constructor(
        address _authority,
        address _owner
    )
    {
        AUTHORITY = _authority;
        owner = _owner;
    }

    /*
     * CORE FUNCTIONS
     */
    /// @dev Allows a factory which is an authority to register a pool.
    /// @param _poolAddress Address of the pool.
    /// @param _name Name of the pool.
    /// @param _symbol Symbol of the pool.
    function register(
        address _poolAddress,
        string calldata _name,
        string calldata _symbol,
        bytes32 id
    )
        external
        payable
        override
        onlyAuthority
        whenAddressFree(_poolAddress)
        whenNameLengthCorrect(_name)
        whenSymbolLengthCorrect(_symbol)
    {
        LibSanitize.assertIsValidCheck(_name);
        LibSanitize.assertIsValidCheck(_symbol);
        LibSanitize.assertIsUppercase(_symbol);
        bytes32 name = bytes32(bytes(_name));
        _assertNameIsFree(name);
        registerAs(_poolAddress, name, id, msg.sender);
        emit Registered(msg.sender, bytes32(bytes(_symbol)), name, id, _poolAddress);
    }

    /// @dev Allows pool owner to set metadata for a pool
    /// @param _id Number corresponding to pool id
    /// @param _key Bytes32 of the key
    /// @param _value Bytes32 of the value
    function setMeta(uint256 _id, bytes32 _key, bytes32 _value)
        external
        override
        onlyPoolOwner(_id)
    {
        poolMetaById[bytes32(_id)].meta[_key] = _value;
        emit MetaChanged(bytes32(_id), _key, _value);
    }

    /// @dev Allows owner to add a group of pools (a factory)
    /// @param _group Address of the new group
    function addGroup(address _group)
        external
        override
        onlyOwner
    {
        groups.push(_group);
    }

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    /// @dev Provides a pool's struct data
    /// @param _id Registration number of the pool
    /// @return poolAddress Pool struct data
    /// @return name Pool struct data
    /// @return group Pool struct data
    function fromId(uint256 _id)
        public
        view
        override
        returns (
            address poolAddress,
            string memory name,
            address group
        )
    {
        return (
            poolAddress = poolById[bytes32(_id)].poolAddress,
            name = string(abi.encodePacked(poolById[bytes32(_id)].name)),
            group = poolById[bytes32(_id)].group
        );
    }

    /// @dev Provides a pool's struct data
    /// @param _poolAddress Address of the pool
    /// @return id Pool struct data
    /// @return name Pool struct data
    /// @return group Pool struct data
    function fromAddress(address _poolAddress)
        external
        view
        override
        returns (
            uint256 id,
            string memory name,
            address group
        )
    {
        id = uint256(mapFromAddress[_poolAddress]);
        return (
            id,
            name = string(abi.encodePacked(poolById[bytes32(id)].name)),
            group = poolById[bytes32(id)].group
        );
    }

    /// @dev Provides a pool's name from its address
    /// @param _poolAddress Address of the pool
    /// @return Name of the pool
    function getNameFromAddress(address _poolAddress)
        external
        view
        override
        returns (string memory)
    {
        uint256 id = uint256(mapFromAddress[_poolAddress]);
        return string(abi.encodePacked(poolById[bytes32(id)].name));
    }

    /// @dev Provides a pool's metadata
    /// @param _id Id number of the pool
    /// @param _key Bytes32 key
    /// @return Pool metadata
    function getMeta(uint256 _id, bytes32 _key)
        external
        view
        override
        returns (bytes32)
    {
        return poolMetaById[bytes32(_id)].meta[_key];
    }

    /// @dev Provides the addresses of the groups/factories
    /// @return Array of addresses of the groups
    function getGroups()
        external
        view
        override
        returns (address[] memory)
    {
        return groups;
    }

    /*
     * INTERNAL FUNCTIONS
     */
    function _assertNameIsFree(bytes32 _name)
        internal
        view
    {
        require(
            mapFromName[_name] == bytes32(0),
            "REGISTRY_NAME_ALREADY_REGISTERED_ERROR"
        );
    }

    /// @dev Allows authority to register a pool for a certain group
    /// @param _poolAddress Address of the pool
    /// @param _name Name of the pool
    /// @param _group Address of the group/factory
    function registerAs(
        address _poolAddress,
        bytes32 _name,
        bytes32 _poolId,
        address _group)
        internal
    {
        poolById[_poolId] = Pool({
            poolAddress: _poolAddress,
            group: _group,
            name: _name
        });
        mapFromAddress[_poolAddress] = _poolId;
        mapFromName[_name] = _poolId;
    }
}
