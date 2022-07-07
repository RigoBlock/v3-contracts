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

    using LibSanitize for string;

    address public AUTHORITY;
    uint256 public VERSION;

    uint256 public fee = 0;

    address[] groups;

    Drago[] dragos;

    mapping (address => uint256) private mapFromAddress;
    mapping (bytes32 => address) private mapFromKey;
    mapping (bytes32 => uint256) private mapFromName;
    mapping (uint256 => mapping (bytes32 => bytes32)) private meta;

    struct Drago {
        address drago;
        bytes32 name;
        bytes32 symbol;
        uint256 dragoId;
        address owner;
        address group;
    }

    /*
     * MODIFIERS
     */
    modifier whenFeePaid {
        require(
            msg.value >= fee,
            "REGISTRY_FEE_NOT_PAID_ERROR"
        );
        _;
    }

    modifier whenAddressFree(address _drago) {
        require(
            mapFromAddress[_drago] == 0,
            "REGISTRY_ADDRESS_ALREADY_TAKEN_ERROR"
        );
        _;
    }

    modifier onlyDragoOwner(uint256 _id) {
        require(
            dragos[_id].owner == msg.sender,
            "REGISTRY_CALLER_IS_NOT_POOL_OWNER_ERROR"
        );
        _;
    }

    modifier whenNameFree(string memory _name) {
        require(
            mapFromName[bytes32(bytes(_name))] == 0,
            "REGISTRY_NAME_ALREADY_REGISTERED_ERROR"
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
        whenNameLengthCorrect(_name)
        whenSymbolLengthCorrect(_symbol)
        whenNameFree(_name)
        returns (uint256 poolId)
    {
        LibSanitize.assertIsValidCheck(_name);
        LibSanitize.assertIsValidCheck(_symbol);
        LibSanitize.assertIsUppercase(_symbol);
        unchecked{ poolId = dragos.length + 1; }
        registerAs(_drago, _name, _symbol, poolId, _owner, msg.sender);
    }

    /// @dev Allows owner to unregister a pool
    /// @param _id Number of the pool
    function unregister(uint256 _id)
        external
        override
        onlyOwner
    {
        uint256 _position;
        unchecked{ _position = _id - 1; }
        delete mapFromAddress[dragos[_position].drago];
        delete mapFromName[dragos[_position].name];
        delete dragos[_position];
        emit Unregistered(dragos[_position].name, dragos[_position].symbol, _id);
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
        meta[_id][_key] = _value;
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
        uint256 position;
        unchecked { position = _id -1; }
        for (uint256 i; i < 32; i++) {
            bytesName[i] = dragos[position].name[i];
            bytesSymbol[i] = dragos[position].symbol[i];
        }
        return (
            drago = dragos[position].drago,
            name = string(bytesName),
            symbol = string(bytesSymbol),
            dragoId = dragos[position].dragoId,
            owner = getPoolOwner(drago),
            group = dragos[position].group
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
        uint256 position;
        unchecked{ position = id - 1; }
        bytes memory bytesName = new bytes(32);
        bytes memory bytesSymbol = new bytes(32);
        for (uint256 i; i < 32; i++) {
            bytesName[i] = dragos[position].name[i];
            bytesSymbol[i] = dragos[position].symbol[i];
        }
        return (
            id,
            name = string(bytesName),
            symbol = string(bytesSymbol),
            dragoId = dragos[position].dragoId,
            owner = getPoolOwner(_drago),
            group = dragos[position].group
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
    function getMeta(uint256 _id, bytes32 _key)
        external
        view
        override
        returns (bytes32)
    {
        return meta[_id][_key];
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
        uint256 _poolId,
        address _owner,
        address _group)
        internal
        returns (uint256)
    {
        // TODO: check whether we want to keep the array or just mapping
        dragos.push(
            Drago({
                drago: _drago,
                name: bytes32(bytes(_name)),
                symbol: bytes32(bytes(_symbol)),
                dragoId: _poolId,
                owner: _owner,
                group: _group
            })
        );
        mapFromAddress[_drago] = _poolId;
        mapFromName[bytes32(bytes(_name))] = _poolId;
        emit Registered(bytes32(bytes(_name)), bytes32(bytes(_symbol)), _poolId, _drago, _owner, _group);
        return _poolId;
    }

    /// @dev Allows anyone to update the owner in the registry
    /// @notice pool owner can change, but gets written in registry only when needed
    /// @param _id uint256 of the target pool
    /// @return Boolean the transaction was successful
    function updateOwnerInternal(uint256 _id)
        internal
        returns (bool)
    {
        Drago storage pool = dragos[_id];
        address targetPool;
        ( targetPool, , , , , ) = fromId(_id);
        require(
            getPoolOwner(targetPool) != pool.owner,
            "REGISTRY_POOL_OWNER_UPDATE_ERROR"
        );
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
