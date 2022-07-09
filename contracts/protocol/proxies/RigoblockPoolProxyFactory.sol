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
import { OwnedUninitialized as Owned } from "../../utils/owned/OwnedUninitialized.sol";
import { IRigoblockPoolProxyFactory } from "../interfaces/IRigoblockPoolProxyFactory.sol";
import { RigoblockPoolProxy } from "./RigoblockPoolProxy.sol";

/// @title Rigoblock Pool Proxy Factory contract - allows creation of new Rigoblock pools.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract RigoblockPoolProxyFactory is Owned, IRigoblockPoolProxyFactory {

    string public constant VERSION = "DF 3.0.0";
    address private _poolImplementation;

    Data private data;

    struct Data {
        uint256 fee;
        address payable rigoblockDao;
        address authority;
        PoolRegistry registry;
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
        owner = _owner;
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
        returns (address newPoolAddress)
    {
        (bytes32 poolId, RigoblockPoolProxy proxy) = _createPoolInternal(_name, _symbol);
        newPoolAddress = address(proxy);
        try data.registry.register(
            newPoolAddress,
            _name,
            _symbol,
            poolId
        ) {
            emit PoolCreated(newPoolAddress);
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
    // TODO: move beneficiary to rigoblock dao, remove following method.
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
    function getStorage()
        external
        view
        override
        returns (
            address rigoblockDao,
            string memory version
        )
    {
        return (
            rigoblockDao = data.rigoblockDao,
            version = VERSION
        );
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
    function _createPoolInternal(
        string calldata _name,
        string calldata _symbol
    )
        internal
        returns (
            bytes32 salt,
            RigoblockPoolProxy proxy
        )
    {
        bytes memory encodedInitialization = abi.encodeWithSelector(
            0x95d317f0, // RigoblockPool._initializePool.selector
            _name,
            _symbol,
            msg.sender,
            data.authority
        );
        salt = keccak256(encodedInitialization);
        bytes memory deploymentData = abi.encodePacked(
            type(RigoblockPoolProxy).creationCode, // bytecode
            abi.encode(
                uint256(uint160(address(this))), // beacon
                encodedInitialization // encoded initialization call
            )
        );
        assembly {
            proxy := create2(0x0, add(0x20, deploymentData), mload(deploymentData), salt)
        }
        require(
            address(proxy) != address(0),
            "FACTORY_LIBRARY_CREATE2_FAILED_ERROR"
        );
    }
}
