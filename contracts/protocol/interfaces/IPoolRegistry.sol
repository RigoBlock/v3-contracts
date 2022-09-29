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

pragma solidity >=0.7.0 <0.9.0;

/// @title Pool Registry Interface - Allows external interaction with pool registry.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
interface IPoolRegistry {
    /// @notice Mapping of pool meta by pool key.
    /// @param meta Mapping of bytes32 key to bytes32 meta.
    struct PoolMeta {
        mapping(bytes32 => bytes32) meta;
    }

    /// @notice Emitted when Rigoblock Dao updates authority address.
    /// @param authority Address of the new authority contract.
    event AuthorityChanged(address indexed authority);

    /// @notice Emitted when pool owner updates meta data for its pool.
    /// @param poolAddress Address of the pool.
    /// @param key Bytes32 key for indexing.
    /// @param value Value associated with the key.
    event MetaChanged(address indexed poolAddress, bytes32 indexed key, bytes32 value);

    /// @notice Emitted when a new pool is registered in registry.
    /// @param group Address of the pool factory.
    /// @param poolAddress Address of the registered pool.
    /// @param name String name of the pool.
    /// @param symbol String name of the pool.
    /// @param id Bytes32 id of the pool.
    event Registered(
        address indexed group,
        address poolAddress,
        bytes32 indexed name, // client can prune sibyl pools
        bytes32 indexed symbol,
        bytes32 id
    );

    /// @notice Emitted when rigoblock Dao address is updated.
    /// @param rigoblockDaoAddress New Dao address.
    event RigoblockDaoChanged(address indexed rigoblockDaoAddress);

    /// @notice Returns the address of the Rigoblock authority contract.
    /// @return Address of the authority contract.
    function authority() external view returns (address);

    /// @notice Returns the address of the Rigoblock Dao.
    /// @return Address of the Rigoblock Dao.
    function rigoblockDaoAddress() external view returns (address);

    /// @notice Allows a factory which is an authority to register a pool.
    /// @param _poolAddress Address of the pool.
    /// @param _name Name of the pool.
    /// @param _symbol Symbol of the pool.
    function register(
        address _poolAddress,
        string calldata _name,
        string calldata _symbol,
        bytes32 poolId
    ) external;

    /// @notice Allows Rigoblock governance to update authority.
    /// @param _authority Address of the authority contract.
    function setAuthority(address _authority) external;

    /// @notice Allows pool owner to set metadata for a pool.
    /// @param _poolAddress Address of the pool.
    /// @param _key Bytes32 of the key.
    /// @param _value Bytes32 of the value.
    function setMeta(
        address _poolAddress,
        bytes32 _key,
        bytes32 _value
    ) external;

    /// @notice Allows Rigoblock Dao to update its address.
    /// @dev Creates internal record.
    /// @param _newRigoblockDao Address of the Rigoblock Dao.
    function setRigoblockDao(address _newRigoblockDao) external;

    /// @notice Returns metadata for a given pool.
    /// @param _poolAddress Address of the pool.
    /// @param _key Bytes32 key.
    /// @return poolMeta Meta by key.
    function getMeta(address _poolAddress, bytes32 _key) external view returns (bytes32 poolMeta);

    /// @notice Returns the id of a pool from its address.
    /// @param _poolAddress Address of the pool.
    /// @return poolId Id of the pool.
    function getPoolIdFromAddress(address _poolAddress) external view returns (bytes32 poolId);
}
