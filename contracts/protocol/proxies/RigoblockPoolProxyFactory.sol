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

import { IDragoRegistry as DragoRegistry } from "../interfaces/IDragoRegistry.sol";
import { IRigoblockV3Pool as RigoblockV3Pool } from "../IRigoblockV3Pool.sol";
import { RigoblockPoolProxyFactoryLibrary } from "./RigoblockPoolProxyFactoryLibrary.sol";
import { OwnedUninitialized as Owned } from "../../utils/owned/OwnedUninitialized.sol";
import { IRigoblockPoolProxyFactory } from "../interfaces/IRigoblockPoolProxyFactory.sol";

/// @title Rigoblock Pool Proxy Factory contract - allows creation of new Rigoblock pools.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract RigoblockPoolProxyFactory is Owned, IRigoblockPoolProxyFactory {

    RigoblockPoolProxyFactoryLibrary.NewPool private libraryData;

    address private _poolImplementation;
    string public constant VERSION = "DF 3.0.1";

    Data private data;

    struct Data {
        uint256 fee;
        address payable dragoDao;
        address authority;
        mapping(address => address[]) dragos;
        DragoRegistry registry;
    }

    modifier whenFeePaid {
        require(msg.value >= data.fee);
        _;
    }

    modifier onlyDragoDao {
        require(msg.sender == data.dragoDao);
        _;
    }

    /// @dev owner is input as we are using factory deterministic deployment.
    constructor(
        address payable _registry,
        address payable _dragoDao,
        address _authority,
        address _owner,
        address _implementation)
    {
        data.registry = DragoRegistry(_registry);
        data.dragoDao = _dragoDao;
        data.authority = _authority;
        owner = _owner;
        _poolImplementation = _implementation;
    }

    /*
     * PUBLIC FUNCTIONS
     */
    /// @dev allows creation of a new drago
    /// @param _name String of the name
    /// @param _symbol String of the symbol
    /// @return Address of the new pool
    function createDrago(string calldata _name, string calldata _symbol)
        external
        payable
        override
        whenFeePaid
        returns (address)
    {
        createDragoInternal(_name, _symbol, msg.sender);
        try data.registry.register{ value : data.registry.getFee() } (
            libraryData.newAddress,
            _name,
            _symbol,
            msg.sender
        ) returns (uint256 poolId)
        {
            emit DragoCreated(_name, _symbol, libraryData.newAddress, owner, poolId);
            return libraryData.newAddress;
        } catch Error(string memory) {
            revert("REGISTRY_POOL_FACTORY_CREATION_ERROR");
        }
    }

    // TODO: this method should be moved to the implementation/beacon, or drago should query dao from factory, not in storage
    /// @dev Allows factory owner to update the address of the dao/factory
    /// @dev Enables manual update of dao for single dragos
    /// @param _targetDrago Address of the target drago
    /// @param _dragoDao Address of the new drago dao
    function setTargetDragoDao(address payable _targetDrago, address _dragoDao)
        external
        override
        onlyOwner
    {
        RigoblockV3Pool(_targetDrago).changeDragoDao(_dragoDao);
    }

    /// @dev Allows drago dao/factory to update its address
    /// @dev Creates internal record
    /// @param _newDragoDao Address of the drago dao
    function changeDragoDao(address payable _newDragoDao)
        external
        override
        onlyDragoDao
    {
        data.dragoDao = _newDragoDao;
    }

    /// @dev Allows owner to update the registry
    /// @param _newRegistry Address of the new registry
    function setRegistry(address _newRegistry)
        external
        override
        onlyOwner
    {
        data.registry = DragoRegistry(_newRegistry);
    }

    /// @dev Allows owner to set the address which can collect creation fees
    /// @param _dragoDao Address of the new drago dao/factory
    function setBeneficiary(address payable _dragoDao)
        external
        override
        onlyOwner
    {
        data.dragoDao = _dragoDao;
    }

    /// @dev Allows owner to set the drago creation fee
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
        onlyDragoDao
    {
        _poolImplementation = _newImplementation;
    }

    /// @dev Allows owner to collect fees
    function drain()
        external
        override
        onlyOwner
    {
        data.dragoDao.transfer(address(this).balance);
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
    /// @return dragoDao Address of the drago dao
    /// @return version String of the version
    /// @return nextDragoId Number of the next drago from the registry
    function getStorage()
        external
        view
        override
        returns (
            address dragoDao,
            string memory version,
            uint256 nextDragoId
        )
    {
        return (
            dragoDao = data.dragoDao,
            version = VERSION,
            nextDragoId = nextPoolId()
        );
    }

    /// @dev Returns an array of dragos the owner has created
    /// @param _owner Address of the queried owner
    /// @return Array of drago addresses
    function getDragosByAddress(address _owner)
        external
        view
        override
        returns (address[] memory)
    {
        return data.dragos[_owner];
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
    /// @dev Creates a drago and routes to eventful
    /// @param _name String of the name
    /// @param _symbol String of the symbol
    /// @param _owner Address of the owner
    function createDragoInternal(
        string memory _name,
        string memory _symbol,
        address _owner
    )
        internal
    {
        require(
            address(
                RigoblockPoolProxyFactoryLibrary.createPool(
                    libraryData,
                    _name,
                    _symbol,
                    _owner,
                    data.authority
                )
            )  != address(0),
            "PROXY_FACTORY_LIBRARY_DEPLOY_ERROR"
        );
        data.dragos[_owner].push(libraryData.newAddress);
    }

    /// @dev Returns the next Id for a drago
    /// @return nextDragoId Number of the next Id from the registry
    function nextPoolId()
        internal
        view
        returns (uint256 nextDragoId)
    {
        unchecked{ nextDragoId = data.registry.dragoCount() + 1; }
    }
}
