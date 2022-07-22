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

    /*
     * EVENTS
     */
    event Registered(
        address indexed group,
        address poolAddress,
        bytes32 indexed name, // client can prune sibyl pools
        bytes32 indexed symbol,
        bytes32 id
    );

    event MetaChanged(
        address indexed poolAddress,
        bytes32 indexed key,
        bytes32 value
    );

    event AuthorityChanged(address indexed athority);
    event RigoblockDaoChanged(address indexed rigoblockDaoAddress);

    /*
     * STORAGE
    */
    function authority() external view returns (address);

    function rigoblockDaoAddress()external view returns (address);

    /*
     * CORE FUNCTIONS
     */
    function register(
        address _poolAddress,
        string calldata  _name,
        string calldata _symbol,
        bytes32 poolId
    )
        external;

    /// @dev Allows Rigoblock governance to update authority.
    /// @param _authority Address of the authority contract.
    function setAuthority (address _authority)
        external;

    function setMeta(
        address _poolAddress,
        bytes32 _key,
        bytes32 _value
    )
        external;

    /// @dev Allows Rigoblock DAO/factory to update its address
    /// @dev Creates internal record
    /// @param _newRigoblockDao Address of the Rigoblock DAO
    function setRigoblockDao(address _newRigoblockDao) external;

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    function getPoolIdFromAddress(address _poolAddress)
        external
        view
        returns (bytes32 poolAddress);

    function getMeta(
        address _poolAddress,
        bytes32 _key
    )
        external
        view
        returns (bytes32 poolMeta);
}
