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
import { IAuthority as Authority } from "../interfaces/IAuthority.sol";

import { IPoolRegistry } from "../interfaces/IPoolRegistry.sol";

/// @title Pool Registry - Allows registration of pools.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract PoolRegistry is IPoolRegistry, Owned {

    using LibSanitize for string;

    address public immutable AUTHORITY;
    // TODO: we can probably eliminate following as unused
    string public constant VERSION = '2.0.0';

    uint256 private fee = uint256(0);

    address[] groups;

    Pool[] poolsList;

    mapping (address => uint256) private mapFromAddress;
    mapping (bytes32 => address) private mapFromKey;
    mapping (bytes32 => uint256) private mapFromName;
    mapping (uint256 => mapping (bytes32 => bytes32)) private meta;
    //mapping (uint256 => Pool) private poolById;

    struct Pool {
        uint256 poolId;
        address poolAddress;
        address group;
        bytes32 name;
        bytes32 symbol;
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

    modifier whenAddressFree(address _poolAddress) {
        require(
            mapFromAddress[_poolAddress] == 0,
            "REGISTRY_ADDRESS_ALREADY_TAKEN_ERROR"
        );
        _;
    }

    // TODO: must fix following condition
    modifier onlyPoolOwner(uint256 _id) {
        (address poolAddress, , , ) = fromId(_id);
        require(
            Owned(poolAddress).owner() == msg.sender,
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
    /// @param _poolAddress Address of the pool.
    /// @param _name Name of the pool.
    /// @param _symbol Symbol of the pool.
    /// @param _owner Address of the pool owner.
    /// @return poolId Id of the new pool.
    function register(
        address _poolAddress,
        string calldata _name,
        string calldata _symbol,
        address _owner)
        external
        payable
        override
        onlyAuthority
        whenFeePaid
        whenAddressFree(_poolAddress)
        whenNameLengthCorrect(_name)
        whenSymbolLengthCorrect(_symbol)
        whenNameFree(_name)
        returns (uint256 poolId)
    {
        LibSanitize.assertIsValidCheck(_name);
        LibSanitize.assertIsValidCheck(_symbol);
        LibSanitize.assertIsUppercase(_symbol);
        unchecked{ poolId = poolsList.length + 1; }
        registerAs(_poolAddress, _name, _symbol, poolId, _owner, msg.sender);
    }

    /// @dev Allows owner to unregister a pool
    /// @param _id Number of the pool
    function unregister(uint256 _id)
        external
        override
        onlyOwner
    {
        (address poolAddress, string memory name, string memory symbol, ) = fromId(_id);
        uint256 _position;
        unchecked{ _position = _id - 1; }
        delete mapFromAddress[poolAddress];
        delete mapFromName[bytes32(bytes(name))];
        delete poolsList[_position];
        emit Unregistered(bytes32(bytes(name)), bytes32(bytes(symbol)), _id);
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
    function poolsCount()
        external
        view
        override
        returns (uint256)
    {
        return poolsList.length;
    }

    /// @dev Provides a pool's struct data
    /// @param _id Registration number of the pool
    /// @return poolAddress Pool struct data
    /// @return name Pool struct data
    /// @return symbol Pool struct data
    /// @return group Pool struct data
    function fromId(uint256 _id)
        public
        view
        override
        returns (
            address poolAddress,
            string memory name,
            string memory symbol,
            address group
        )
    {
        // TODO: check string(poolsList[_position].name)
        uint256 position;
        unchecked { position = _id -1; }
        return (
            poolAddress = poolsList[position].poolAddress,
            name = string(abi.encodePacked(poolsList[position].name)),
            symbol = string(abi.encodePacked(poolsList[position].symbol)),
            group = poolsList[position].group
        );
    }

    /// @dev Provides a pool's struct data
    /// @param _poolAddress Address of the pool
    /// @return id Pool struct data
    /// @return name Pool struct data
    /// @return symbol Pool struct data
    /// @return group Pool struct data
    function fromAddress(address _poolAddress)
        external
        view
        override
        returns (
            uint256 id,
            string memory name,
            string memory symbol,
            address group
        )
    {
        id = mapFromAddress[_poolAddress];
        uint256 position;
        unchecked{ position = id - 1; }
        return (
            id,
            name = string(abi.encodePacked(poolsList[position].name)),
            symbol = string(abi.encodePacked(poolsList[position].symbol)),
            group = poolsList[position].group
        );
    }

    /// @dev Provides a pool's struct data
    /// @param _name Name of the pool
    /// @return id Pool struct data
    /// @return poolAddress Pool struct data
    /// @return symbol Pool struct data
    /// @return group Pool struct data
    function fromName(string calldata _name)
        external
        view
        override
        returns (
            uint256 id,
            address poolAddress,
            string memory symbol,
            address group
        )
    {
        id = mapFromName[bytes32(bytes(_name))];
        uint256 position;
        unchecked{ position = id - 1; }
        return (
            id,
            poolAddress = poolsList[position].poolAddress,
            symbol = string(abi.encodePacked(poolsList[position].symbol)),
            group = poolsList[position].group
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
        uint256 id = mapFromAddress[_poolAddress];
        uint256 position;
        unchecked{ position = id - 1; }
        return string(abi.encodePacked(poolsList[position].name));
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
        uint256 position;
        unchecked{ position = id - 1; }
        return string(abi.encodePacked(poolsList[position].symbol));
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
    /// @param _poolAddress Address of the pool
    /// @param _name Name of the pool
    /// @param _symbol Symbol of the pool
    /// @param _owner Address of the pool owner
    /// @param _group Address of the group/factory
    function registerAs(
        address _poolAddress,
        string memory _name,
        string memory _symbol,
        uint256 _poolId,
        address _owner,
        address _group)
        internal
    {
        // TODO: check whether we want to keep the array or just mapping
        poolsList.push(
            Pool({
                poolId: _poolId,
                poolAddress: _poolAddress,
                group: _group,
                name: bytes32(bytes(_name)),
                symbol: bytes32(bytes(_symbol))
            })
        );
        mapFromAddress[_poolAddress] = _poolId;
        mapFromName[bytes32(bytes(_name))] = _poolId;
        emit Registered(bytes32(bytes(_name)), bytes32(bytes(_symbol)), _poolId, _poolAddress, _owner, _group);
    }
}
