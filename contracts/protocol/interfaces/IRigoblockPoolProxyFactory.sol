// SPDX-License-Identifier: Apache-2.0-or-later
/*

 Copyright 2017-2022 RigoBlock, Rigo Investment Sagl, Rigo Intl.

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

/// @title Pool Proxy Factory Interface - Allows external interaction with Pool Proxy Factory.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
interface IRigoblockPoolProxyFactory {

    event PoolCreated(
        address poolAddress
    );

    function createPool(
        string calldata _name,
        string calldata _symbol
    )
        external
        payable
        returns (address newPoolAddress);

    // TODO: eliminate this method and pay fees to rigoblock dao. Pool queries from its factory
    function setTargetRigoblockDao(
        address payable _targetPool,
        address _rigoblockDao
    )
        external;

    function changeRigoblockDao( address payable _newRigoblockDao)
        external;

    function setRegistry(address _newRegistry)
        external;

    function setImplementation(address _newImplementation)
        external;

    function getRegistry()
        external
        view
        returns (address);

    function getRigoblockDaoAddress()
        external
        view
        returns (address);

    function implementation()
        external
        view
        returns (address);
}
