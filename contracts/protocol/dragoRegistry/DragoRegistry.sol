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
import { IAuthority as Authority } from "../interfaces/IAuthority.sol";
import { LibSanitize } from "../../utils/LibSanitize/LibSanitize.sol";

import { IDragoRegistry } from "../interfaces/IDragoRegistry.sol";

/// @title Drago Registry - Allows registration of pools.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract DragoRegistry is IDragoRegistry, Owned {

    using LibSanitize for bool;

    address public AUTHORITY;
    uint256 public VERSION;

    uint256 public fee = 0;

    address[] groups;

    Drago[] dragos;

    mapping (address => uint256) mapFromAddress;
    mapping (bytes32 => address) mapFromKey;
    mapping (bytes32 => uint256) mapFromName;

    struct Drago {
        address drago;
        bytes32 name;
        bytes32 symbol;
        uint256 dragoId;
        address owner;
        address group;
        mapping (bytes32 => bytes32) meta;
    }

    /*
     * MODIFIERS
     */
    modifier whenFeePaid {
        require(msg.value >= fee);
        _;
    }

    modifier whenAddressFree(address _drago) {
        require(mapFromAddress[_drago] == 0);
        _;
    }

    modifier onlyDragoOwner(uint256 _id) {
        require(dragos[_id].owner == msg.sender);
        _;
    }

    modifier whenNameFree(string memory _name) {
        require(
            mapFromName[bytes32(bytes(_name))] == 0,
            "REGISTRY_NAME_ALREADY_REGISTERED_ERROR"
        );
        _;
    }

    modifier whenNameSanitized(string memory _input) {
        // we always want to keep name lenght below 32, for logging bytes32.
        require(bytes(_input).length >= 4 && bytes(_input).length <= 32);
        require(LibSanitize.isValidCheck(_input));
        _;
    }

    modifier whenSymbolSanitized(string memory _input) {
        require(bytes(_input).length >= 3 && bytes(_input).length <= 5);
        require(LibSanitize.isValidCheck(_input));
        require(LibSanitize.isUppercase(_input));
        _;
    }

    modifier whenHasName(string memory _name) {
        require(
            mapFromName[bytes32(bytes(_name))] != 0,
            "REGISTRY_POOL_DOES_NOT_HAVE_NAME_ERROR"
        );
        _;
    }

    modifier onlyAuthority {
        Authority auth = Authority(AUTHORITY);
        require(auth.isAuthority(msg.sender) == true);
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
    /// @param _drago Address of the pool.
    /// @param _name Name of the pool.
    /// @param _symbol Symbol of the pool.
    /// @param _owner Address of the pool owner.
    /// @return poolId Id of the new pool.
    function register(
        address _drago,
        string calldata _name,
        string calldata _symbol,
        address _owner)
        external
        payable
        override
        onlyAuthority
        whenFeePaid
        whenAddressFree(_drago)
        whenNameSanitized(_name)
        whenSymbolSanitized(_symbol)
        whenNameFree(_name)
        returns (uint256 poolId)
    {
        return registerAs(_drago, _name, _symbol, _owner, msg.sender);
    }

    /// @dev Allows owner to unregister a pool
    /// @param _id Number of the pool
    function unregister(uint256 _id)
        external
        override
        onlyOwner
    {
        delete mapFromAddress[dragos[_id].drago];
        delete mapFromName[dragos[_id].name];
        delete dragos[_id];
        emit Unregistered(dragos[_id].name, dragos[_id].symbol, _id);
    }

    /// @dev Allows pool owner to set metadata for a pool
    /// @param _id Number corresponding to pool id
    /// @param _key Bytes32 of the key
    /// @param _value Bytes32 of the value
    function setMeta(uint256 _id, bytes32 _key, bytes32 _value)
        external
        override
        onlyDragoOwner(_id)
    {
        dragos[_id].meta[_key] = _value;
        emit MetaChanged(_id, _key, _value);
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

    /// @dev Allows owner to set a fee to register pools
    /// @param _fee Value of the fee in wei
    function setFee(uint256 _fee)
        external
        override
        onlyOwner
    {
        fee = _fee;
    }

    /// @dev Allows anyone to update the owner in the registry
    /// @notice pool owner can change; gets written in registry only when needed
    /// @param _id uint256 of the target pool
    function updateOwner(uint256 _id)
        external
        override
    {
        updateOwnerInternal(_id);
    }

    /// @dev Allows anyone to update many owners if they differ from registered
    /// @param _id uint256 of the target pool
    function updateOwners(uint256[] calldata _id)
        external
        override
    {
        for (uint256 i = 0; i < _id.length; ++i) {
            if (!updateOwnerInternal(_id[i])) continue;
        }
    }

    /// @dev Allows owner to create a new registry.
    /// @dev When the registry gets upgraded, a migration of all funds is required
    /// @param _newAddress Address of new registry.
    function upgrade(address _newAddress)
        external
        payable
        override
        onlyOwner
    {
        DragoRegistry registry = DragoRegistry(_newAddress);
        ++VERSION;
        registry.setUpgraded(VERSION);
        address payable registryAddress = payable(address(uint160(address(registry))));
        registryAddress.transfer(address(this).balance);
    }

    /// @dev Allows owner to update version on registry upgrade
    /// @param _version Number of the new version
    function setUpgraded(uint256 _version)
        external
        override
        onlyOwner
    {
        VERSION = _version;
    }

    /// @dev Allows owner to collect fees by draining the balance
    function drain()
        external
        override
        onlyOwner
    {
        payable(msg.sender).transfer(address(this).balance);
    }

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    /// @dev Provides the total number of registered pools
    /// @return Number of pools
    function dragoCount()
        external
        view
        override
        returns (uint256)
    {
        return dragos.length;
    }

    /// @dev Provides a pool's struct data
    /// @param _id Registration number of the pool
    /// @return drago Pool struct data
    /// @return name Pool struct data
    /// @return symbol Pool struct data
    /// @return dragoId Pool struct data
    /// @return owner Pool struct data
    /// @return group Pool struct data
    function fromId(uint256 _id)
        public
        view //prev external
        override
        returns (
            address drago,
            string memory name,
            string memory symbol,
            uint256 dragoId,
            address owner,
            address group
        )
    {
        bytes memory bytesName = new bytes(32);
        bytes memory bytesSymbol = new bytes(32);
        for (uint256 i; i < 32; i++) {
            bytesName[i] = dragos[_id].name[i];
            bytesSymbol[i] = dragos[_id].symbol[i];
        }
        return (
            drago = dragos[_id].drago,
            name = string(bytesName),
            symbol = string(bytesSymbol),
            dragoId = dragos[_id].dragoId,
            owner = getPoolOwner(drago),
            group = dragos[_id].group
        );
    }

    /// @dev Provides a pool's struct data
    /// @param _drago Address of the pool
    /// @return id Pool struct data
    /// @return name Pool struct data
    /// @return symbol Pool struct data
    /// @return dragoId Pool struct data
    /// @return owner Pool struct data
    /// @return group Pool struct data
    function fromAddress(address _drago)
        external
        view
        override
        returns (
            uint256 id,
            string memory name,
            string memory symbol,
            uint256 dragoId,
            address owner,
            address group
        )
    {
        id = mapFromAddress[_drago];
        bytes memory bytesName = new bytes(32);
        bytes memory bytesSymbol = new bytes(32);
        for (uint256 i; i < 32; i++) {
            bytesName[i] = dragos[id].name[i];
            bytesSymbol[i] = dragos[id].symbol[i];
        }
        return (
            id,
            name = string(bytesName),
            symbol = string(bytesSymbol),
            dragoId = dragos[id].dragoId,
            owner = getPoolOwner(_drago),
            group = dragos[id].group
        );
    }

    /// @dev Provides a pool's struct data
    /// @param _name Name of the pool
    /// @return id Pool struct data
    /// @return drago Pool struct data
    /// @return symbol Pool struct data
    /// @return dragoId Pool struct data
    /// @return owner Pool struct data
    /// @return group Pool struct data
    function fromName(string calldata _name)
        external
        view
        override
        returns (
            uint256 id,
            address drago,
            string memory symbol,
            uint256 dragoId,
            address owner,
            address group
        )
    {
        id = mapFromName[bytes32(bytes(_name))];
        bytes memory bytesSymbol = new bytes(32);
        for (uint256 i; i < 32; i++) {
            bytesSymbol[i] = dragos[id].symbol[i];
        }
        return (
            id,
            drago = dragos[id].drago,
            symbol = string(bytesSymbol),
            dragoId = dragos[id].dragoId,
            owner = getPoolOwner(drago),
            group = dragos[id].group
        );
    }

    /// @dev Provides a pool's name from its address
    /// @param _pool Address of the pool
    /// @return Name of the pool
    function getNameFromAddress(address _pool)
        external
        view
        override
        returns (string memory)
    {
        uint256 id = mapFromAddress[_pool];
        bytes memory bytesName = new bytes(32);
        for (uint256 i; i < 32; i++) {
            bytesName[i] = dragos[id].name[i];
        }
        return string(bytesName);
    }

    /// @dev Provides a pool's symbol from its address
    /// @param _pool Address of the pool
    /// @return Symbol of the pool
    function getSymbolFromAddress(address _pool)
        external
        view
        override
        returns (string memory)
    {
        uint256 id = mapFromAddress[_pool];
        bytes memory bytesSymbol = new bytes(32);
        for (uint256 i; i < 32; i++) {
            bytesSymbol[i] = dragos[id].symbol[i];
        }
        return string(bytesSymbol);
    }

    /// @dev Provides a pool's metadata
    /// @param _id Id number of the pool
    /// @param _key Bytes32 key
    /// @return Pool metadata
    function meta(uint256 _id, bytes32 _key)
        external
        view
        override
        returns (bytes32)
    {
        return dragos[_id].meta[_key];
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

    /// @dev Provides the fee required to register a pool
    /// @return Number of the fee in wei
    function getFee()
        external
        view
        override
        returns (uint256)
    {
        return fee;
    }

    /*
     * INTERNAL FUNCTIONS
     */
    /// @dev Allows authority to register a pool for a certain group
    /// @param _drago Address of the pool
    /// @param _name Name of the pool
    /// @param _symbol Symbol of the pool
    /// @param _owner Address of the pool owner
    /// @param _group Address of the group/factory
    function registerAs(
        address _drago,
        string memory _name,
        string memory _symbol,
        address _owner,
        address _group)
        internal
        returns (uint256)
    {
        Drago storage pool = dragos.push();
        pool.drago = _drago;
        pool.name = bytes32(bytes(_name));
        pool.symbol = bytes32(bytes(_symbol));
        pool.dragoId = dragos.length + 1;
        pool.owner = _owner;
        pool.group = _group;
        // TODO: check whether the both following are needed
        mapFromAddress[_drago] = dragos.length;
        mapFromName[bytes32(bytes(_name))] = dragos.length;
        emit Registered(pool.name, pool.symbol, dragos.length, _drago, _owner, _group);
        unchecked{ return pool.dragoId; }
    }

    /// @dev Allows anyone to update the owner in the registry
    /// @notice pool owner can change, but gets written in registry only when needed
    /// @param _id uint256 of the target pool
    /// @return Bollean the transaction was successful
    function updateOwnerInternal(uint256 _id)
        internal
        returns (bool)
    {
        Drago storage pool = dragos[_id];
        address targetPool;
        ( targetPool, , , , , ) = fromId(_id);
        require(getPoolOwner(targetPool) != pool.owner);
        pool.owner = getPoolOwner(targetPool);
        return true;
    }

    /// @dev Returns the actual owner of a pool
    /// @notice queries from the target pool contract itself
    /// @param pool Address of the target pool
    /// @return Address of the pool owner
    function getPoolOwner(address pool)
        internal view
        returns (address)
    {
        return Owned(pool).owner();
    }
}
