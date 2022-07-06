// SPDX-License-Identifier: Apache-2.0-or-later
/*

 Copyright 2022 Rigo Intl.

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

import { IPoolRegistry as PoolRegistry } from "../interfaces/IPoolRegistry.sol";
import { IRigoblockV3Pool as RigoblockV3Pool } from "../IRigoblockV3Pool.sol";
import { RigoblockPoolProxyFactoryLibrary } from "./RigoblockPoolProxyFactoryLibrary.sol";
import { OwnedUninitialized as Owned } from "../../utils/owned/OwnedUninitialized.sol";
import { IRigoblockPoolProxyFactory } from "../interfaces/IRigoblockPoolProxyFactory.sol";

/// @title Rigoblock Pool Proxy Factory contract - allows creation of new Rigoblock pools.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract RigoblockPoolProxyFactory is Owned, IRigoblockPoolProxyFactory {

    RigoblockPoolProxyFactoryLibrary.NewPool private libraryData;

    string public constant VERSION = "DF 3.0.0";
    address private _poolImplementation;

    Data private data;

    mapping(address => address[]) private poolAddressesByOwner;

    struct Data {
        uint256 fee;
        address payable rigoblockDao;
        address authority;
        PoolRegistry registry;
    }

    modifier whenFeePaid {
        require(
            msg.value >= data.fee,
            "FACTORY_FEE_NOT_PAID_ERROR"
        );
        _;
    }

    modifier onlyRigoblockDao {
        require(
            msg.sender == data.rigoblockDao,
            "FACTORY_SENDER_NOT_DAO_ERROR"
        );
        _;
    }

    /// @dev owner is input as we are using factory deterministic deployment.
    constructor(
        address payable _registry,
        address payable _rigoblockDao,
        address _authority,
        address _owner,
        address _implementation)
    {
        data.registry = PoolRegistry(_registry);
        data.rigoblockDao = _rigoblockDao;
        data.authority = _authority;
        owner = _owner; // TODO: check owner is correct
        _poolImplementation = _implementation;
    }

    /*
     * PUBLIC FUNCTIONS
     */
    /// @dev allows creation of a new pool
    /// @param _name String of the name
    /// @param _symbol String of the symbol
    /// @return newPoolAddress Address of the new pool
    function createPool(string calldata _name, string calldata _symbol)
        external
        payable
        override
        whenFeePaid
        returns (address newPoolAddress)
    {
        // TODO: check gas savings in sending name and symbol as bytes32 to registry
        try data.registry.register{ value : data.registry.getFee() } (
            createPoolInternal(_name, _symbol, msg.sender),
            _name,
            _symbol,
            msg.sender
        ) returns (uint256 poolId) {
            // TODO: owner can change, array would not be correct. we can avoid storing here
            poolAddressesByOwner[msg.sender].push(libraryData.newAddress);
            newPoolAddress = libraryData.newAddress;
            emit PoolCreated(bytes32(bytes(_name)), bytes32(bytes(_symbol)), libraryData.newAddress, msg.sender, poolId);
        } catch Error(string memory reason) {
            revert(reason);
        } catch (bytes memory returnData) {
            revert(string(returnData));
        }
    }

    // TODO: this method should be moved to the implementation/beacon, or pool should query dao from factory, not in storage
    /// @dev Allows factory owner to update the address of the dao/factory
    /// @dev Enables manual update of dao for single pools
    /// @param _targetPool Address of the target pool
    /// @param _rigoblockDao Address of the new rigoblock dao
    function setTargetRigoblockDao(address payable _targetPool, address _rigoblockDao)
        external
        override
        onlyOwner
    {
        RigoblockV3Pool(_targetPool).changeDragoDao(_rigoblockDao);
    }

    /// @dev Allows Rigoblock DAO/factory to update its address
    /// @dev Creates internal record
    /// @param _newRigoblockDao Address of the Rigoblock DAO
    function changeRigoblockDao(address payable _newRigoblockDao)
        external
        override
        onlyRigoblockDao
    {
        data.rigoblockDao = _newRigoblockDao;
    }

    /// @dev Allows owner to update the registry
    /// @param _newRegistry Address of the new registry
    function setRegistry(address _newRegistry)
        external
        override
        onlyOwner
    {
        data.registry = PoolRegistry(_newRegistry);
    }

    /// @dev Allows owner to set the address which can collect creation fees
    /// @param _rigoblockDao Address of the new Rigoblock DAO/factory
    function setBeneficiary(address payable _rigoblockDao)
        external
        override
        onlyOwner
    {
        data.rigoblockDao = _rigoblockDao;
    }

    /// @dev Allows owner to set the pool creation fee
    /// @param _fee Value of the fee in wei
    function setFee(uint256 _fee)
        external
        override
        onlyOwner
    {
        data.fee = _fee;
    }

    function setImplementation(address _newImplementation)
        external
        override
        onlyRigoblockDao
    {
        _poolImplementation = _newImplementation;
    }

    /// @dev Allows owner to collect fees
    // TODO: move beneficiary to rigoblock dao, remove followin method.
    function drain()
        external
        override
        onlyOwner
    {
        data.rigoblockDao.transfer(address(this).balance);
    }

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    /// @dev Returns the address of the pool registry
    /// @return Address of the registry
    function getRegistry()
        external
        view
        override
        returns (address)
    {
        return (address(data.registry));
    }

    /// @dev Returns administrative data for this factory
    /// @return rigoblockDao Address of the Rigoblock DAO
    /// @return version String of the version
    /// @return nextPoolId Number of the next pool from the registry
    function getStorage()
        external
        view
        override
        returns (
            address rigoblockDao,
            string memory version,
            uint256 nextPoolId
        )
    {
        return (
            rigoblockDao = data.rigoblockDao,
            version = VERSION,
            getNextPoolId()
        );
    }

    /// @dev Returns an array of pools the owner has created
    /// @param _owner Address of the queried owner
    /// @return Array of pool addresses
    function getPoolsByAddress(address _owner)
        external
        view
        override
        returns (address[] memory)
    {
        return poolAddressesByOwner[_owner];
    }

    function implementation()
        external
        view
        override
        returns (address)
    {
        return _poolImplementation;
    }

    /*
     * INTERNAL FUNCTIONS
     */
    /// @dev Creates a pool and routes to eventful
    /// @param _name String of the name
    /// @param _symbol String of the symbol
    /// @param _owner Address of the owner
    function createPoolInternal(
        string memory _name,
        string memory _symbol,
        address _owner
    )
        internal
        returns (address)
    {
        return address(RigoblockPoolProxyFactoryLibrary.createPool(
            libraryData,
            _name,
            _symbol,
            _owner,
            data.authority
        ));
    }

    /// @dev Returns the next Id for a pool
    /// @return nextPoolId Number of the next Id from the registry
    function getNextPoolId()
        internal
        view
        returns (uint256 nextPoolId)
    {
        unchecked{ nextPoolId = data.registry.poolsCount() + 1; }
    }
}
