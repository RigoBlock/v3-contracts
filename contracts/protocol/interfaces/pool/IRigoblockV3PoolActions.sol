// SPDX-License-Identifier: Apache 2.0
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

/// @title Rigoblock V3 Pool Interface - Allows interaction with the pool contract.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
interface IRigoblockV3PoolActions {

    /*
     * CORE FUNCTIONS
     */
    function pay()
        external
        payable;

    function buyDrago()
        external
        payable
        returns (bool success);

    function buyDragoOnBehalf(address _hodler)
        external
        payable
        returns (bool success);

    function sellDrago(uint256 _amount)
        external
        returns (bool success);

    function changeRatio(uint256 _ratio)
        external;

    function changeDragoDao(address _dragoDao)
        external;

    function enforceKyc(bool _enforced, address _kycProvider)
        external;
}