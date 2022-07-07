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
        bytes32 indexed symbol,
        bytes32 name,
        bytes32 id,
        address poolAddress
    );

    event MetaChanged(
        bytes32 indexed id,
        bytes32 indexed key,
        bytes32 value
    );

    /*
     * CORE FUNCTIONS
     */
    function register(
        address _poolAddress,
        string calldata  _name,
        string calldata _symbol,
        bytes32 id
    )
        external
        payable;

    function setMeta(
        uint256 _id,
        bytes32 _key,
        bytes32 _value
    )
        external;

    function addGroup(address _group) external;

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    function fromId(uint256 _id)
        external
        view
        returns (
            address poolAddress,
            string memory name,
            address group
        );

    function fromAddress(address _poolAddress)
        external
        view
        returns (
            uint256 id,
            string memory name,
            address group
        );

    function getNameFromAddress(address _pool)
        external
        view
        returns (string memory);

    function getMeta(
        uint256 _id,
        bytes32 _key
    )
        external
        view
        returns (bytes32);

    function getGroups()
        external
        view
        returns (address[] memory);
}
