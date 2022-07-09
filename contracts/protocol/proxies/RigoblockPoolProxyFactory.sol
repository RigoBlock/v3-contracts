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
import { IRigoblockPoolProxyFactory } from "../interfaces/IRigoblockPoolProxyFactory.sol";
import { RigoblockPoolProxy } from "./RigoblockPoolProxy.sol";

/// @title Rigoblock Pool Proxy Factory contract - allows creation of new Rigoblock pools.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract RigoblockPoolProxyFactory is IRigoblockPoolProxyFactory {

    address public implementation;

    address private authorityAddress;
    address private registryAddress;
    address private rigoblockDaoAddress;

    modifier onlyRigoblockDao {
        require(
            msg.sender == rigoblockDaoAddress,
            "FACTORY_SENDER_NOT_DAO_ERROR"
        );
        _;
    }

    constructor(
        address _authority,
        address _implementation,
        address _registry,
        address _rigoblockDao
    ) {
        authorityAddress = _authority;
        implementation = _implementation;
        registryAddress = _registry;
        rigoblockDaoAddress = _rigoblockDao;
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
        override
        returns (address newPoolAddress)
    {
        (bytes32 poolId, RigoblockPoolProxy proxy) = _createPoolInternal(_name, _symbol);
        newPoolAddress = address(proxy);
        try PoolRegistry(registryAddress).register(
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

    function setAuthority(address _newAuthority)
        external
        override
    {
        require(
            _newAuthority != address(0),
            "FACTORY_NEW_REGISTRY_ADDRESS_NULL_ERROR"
        );
        authorityAddress = _newAuthority;
    }

    function setImplementation(address _newImplementation)
        external
        override
        onlyRigoblockDao
    {
        require(
            _isContract(_newImplementation),
            "NEW_IMPLEMENTATION_NOT_CONTRACT_ERROR"
        );
        implementation = _newImplementation;
    }

    /// @dev Allows owner to update the registry
    /// @param _newRegistry Address of the new registry
    function setRegistry(address _newRegistry)
        external
        override
        onlyRigoblockDao
    {
        require(
            _newRegistry != address(0),
            "FACTORY_NEW_REGISTRY_ADDRESS_NULL_ERROR"
        );
        registryAddress = _newRegistry;
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
            _newRigoblockDao != address(0),
            "FACTORY_NEW_DAO_ADDRESS_NULL_ERROR"
        );
        rigoblockDaoAddress = _newRigoblockDao;
    }

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
     /// @dev Returns the address of the pool registry.
     /// @return Address of the authority.
     function getAuthority()
         external
         view
         override
         returns (address)
     {
         return authorityAddress;
     }

    /// @dev Returns the address of the pool registry
    /// @return Address of the registry
    function getRegistry()
        external
        view
        override
        returns (address)
    {
        return registryAddress;
    }

    /// @dev Returns administrative data for this factory
    /// @return Address of the Rigoblock DAO
    function getRigoblockDaoAddress()
        external
        view
        override
        returns (address)
    {
        return rigoblockDaoAddress;
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
            authorityAddress
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

    function _isContract(address _target)
        private
        view
        returns (bool)
    {
        // TODO: test uin256 vs uint32
        uint32 size;
        assembly {
            size := extcodesize(_target)
        }
        return size > 0;
    }
}
