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
import { LibSanitize } from "../../utils/libSanitize/LibSanitize.sol";
import { IAuthorityCore as Authority } from "../interfaces/IAuthorityCore.sol";

import { IPoolRegistry } from "../interfaces/IPoolRegistry.sol";

/// @title Pool Registry - Allows registration of pools.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract PoolRegistry is IPoolRegistry {

    address public rigoblockDaoAddress;

    address private authority;

    mapping(address => bytes32) private mapIdByAddress;
    mapping(bytes32 => bytes32) private mapIdByName;

    mapping(address => PoolMeta) private poolMetaByAddress;

    struct PoolMeta {
        mapping(bytes32 => bytes32) meta;
    }

    /*
     * MODIFIERS
     */
    modifier onlyAuthority {
        require(
            Authority(authority).isAuthority(msg.sender) == true,
            "REGISTRY_CALLER_IS_NOT_AUTHORITY_ERROR"
        );
        _;
    }

    modifier onlyPoolOwner(address _poolAddress) {
        require(
            Owned(_poolAddress).owner() == msg.sender,
            "REGISTRY_CALLER_IS_NOT_POOL_OWNER_ERROR"
        );
        _;
    }

    modifier onlyRigoblockDao {
        require(
            msg.sender == rigoblockDaoAddress,
            "FACTORY_CALLER_NOT_DAO_ERROR"
        );
        _;
    }

    modifier whenAddressFree(address _poolAddress) {
        require(
            mapIdByAddress[_poolAddress] == bytes32(0),
            "REGISTRY_ADDRESS_ALREADY_TAKEN_ERROR"
        );
        _;
    }

    modifier whenPoolRegistered(address _poolAddress) {
        require(
            mapIdByAddress[_poolAddress] != bytes32(0),
            "REGISTRY_ADDRESS_NOT_REGISTERED_ERROR"
        );
        _;
    }

    constructor(
        address _authority,
        address _rigoblockDao
    ) {
        authority = _authority;
        rigoblockDaoAddress = _rigoblockDao;
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
        bytes32 poolId
    )
        external
        override
        onlyAuthority
        whenAddressFree(_poolAddress)
    {
        _assertValidNameAndSymbol(_name, _symbol);

        bytes32 name = bytes32(bytes(_name));
        _assertNameIsFree(name);

        mapIdByAddress[_poolAddress] = poolId;
        mapIdByName[name] = poolId;

        emit Registered(
            msg.sender, // proxy factory
            _poolAddress,
            bytes32(bytes(_symbol)),
            poolId
        );
    }

    /// @dev Allows pool owner to set metadata for a pool.
    /// @param _poolAddress Address of the pool.
    /// @param _key Bytes32 of the key.
    /// @param _value Bytes32 of the value.
    function setMeta(address _poolAddress, bytes32 _key, bytes32 _value)
        external
        override
        onlyPoolOwner(_poolAddress)
        whenPoolRegistered(_poolAddress)
    {
        poolMetaByAddress[_poolAddress].meta[_key] = _value;
        emit MetaChanged(_poolAddress, _key, _value);
    }

    /// @dev Allows Rigoblock governance to update authority.
    /// @param _authority Address of the authority contract.
    function setAuthority (address _authority)
        external
        override
        onlyRigoblockDao
    {
        require(
            _isContract(_authority),
            "FACTORY_NEW_AUTHORITY_NOT_CONTRACT_ERROR"
        );
        authority = _authority;
    }

    /// @dev Allows Rigoblock DAO/factory to update its address
    /// @dev Creates internal record
    /// @param _newRigoblockDao Address of the Rigoblock DAO
    function setRigoblockDao(address _newRigoblockDao)
        external
        override
        onlyRigoblockDao
    {
        require(
            _isContract(_newRigoblockDao),
            "FACTORY_NEW_DAO_NOT_CONTRACT_ERROR"
        );
        rigoblockDaoAddress = _newRigoblockDao;
    }

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    /// @dev Provides a pool's struct data
    /// @param _poolAddress Address of the pool
    function getPoolIdFromAddress(address _poolAddress)
        external
        view
        override
        returns (bytes32)
    {
        return mapIdByAddress[_poolAddress];
    }

    /// @dev Provides a pool's metadata.
    /// @param _poolAddress Address of the pool.
    /// @param _key Bytes32 key.
    /// @return poolMeta Meta by key.
    function getMeta(address _poolAddress, bytes32 _key)
        external
        view
        override
        returns (bytes32 poolMeta)
    {
        return poolMetaByAddress[_poolAddress].meta[_key];
    }

    /*
     * INTERNAL FUNCTIONS
     */
    function _assertNameIsFree(bytes32 _name)
        internal
        view
    {
        require(
            mapIdByName[_name] == bytes32(0),
            "REGISTRY_NAME_ALREADY_REGISTERED_ERROR"
        );
    }

    function _assertValidNameAndSymbol(
        string memory _name,
        string memory _symbol
    )
        internal
        pure
    {
        uint256 nameLength = bytes(_name).length;
        // we always want to keep name lenght below 32, for logging bytes32.
        require(
            nameLength >= uint256(4) && nameLength <= uint256(32),
            "REGISTRY_NAME_LENGTH_ERROR"
        );

        uint256 symbolLength = bytes(_symbol).length;
        require(
            symbolLength >= uint256(3) && symbolLength <= uint256(5),
            "REGISTRY_SYMBOL_LENGTH_ERROR"
        );

        // check valid characters in name and symbol
        LibSanitize.assertIsValidCheck(_name);
        LibSanitize.assertIsValidCheck(_symbol);
        LibSanitize.assertIsUppercase(_symbol);
    }

    function _isContract(address _target)
        private
        view
        returns (bool)
    {
        uint256 size;
        assembly {
            size := extcodesize(_target)
        }
        return size > 0;
    }
}
