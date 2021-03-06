// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2017-2018 RigoBlock, Rigo Investment Sagl.

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

pragma solidity >=0.5.0 <0.9.0;

/// @title Pool Interface Contract - Interface of pool standard functions.
/// @author Gabriele Rigo - <gab@rigoblock.com>
/// @notice used in order to access public variable
abstract contract Pool {

    address public owner;

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    function balanceOf(address _who) external virtual view returns (uint256);
    function totalSupply() external virtual view returns (uint256 totaSupply);
    function getEventful() external virtual view returns (address);
    function getData() external virtual view returns (string memory name, string memory symbol, uint256 sellPrice, uint256 buyPrice);
    function calcSharePrice() external virtual view returns (uint256);
    function getAdminData() external virtual view returns (address, address feeCollector, address dragodAO, uint256 ratio, uint256 transactionFee, uint32 minPeriod);
}
