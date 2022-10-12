// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2018-2022 RigoBlock, Rigo Investment Sagl, Rigo Intl.

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

import {IPool} from "../../utils/pool/IPool.sol";
import {IPoolRegistry} from "../../protocol/interfaces/IPoolRegistry.sol";

/// @title Network - Returns data of active pools and network value.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract Network {
    // solhint-disable-next-line var-name-mixedcase
    address public POOLREGISTRYADDRESS;

    constructor(address poolRegistryAddress) {
        POOLREGISTRYADDRESS = poolRegistryAddress;
    }

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    /// @dev Returns two arrays of prices and total supply.
    /// @param _poolAddresses Array of addresses.
    /// @return poolPrices Array of the prices of the active pools.
    /// @return totalTokens Array of the number of tokens of each pool.
    function getPoolsPrices(address[] memory _poolAddresses)
        external
        view
        returns (uint256[] memory, uint256[] memory)
    {
        uint256 length = _poolAddresses.length;
        uint256[] memory poolPrices = new uint256[](length);
        uint256[] memory totalTokens = new uint256[](length);
        for (uint256 i = 0; i < length; ++i) {
            IPool poolInstance = IPool(_poolAddresses[i]);
            poolPrices[i] = poolInstance.calcSharePrice();
            totalTokens[i] = poolInstance.totalSupply();
        }
        return (poolPrices, totalTokens);
    }

    /// @dev Returns the value of the assets in the rigoblock network.
    /// @param _addresses Array of addresses.
    /// @return networkValue alue of the rigoblock network in wei.
    /// @return numberOfPools Number of active funds.
    function calcNetworkValue(address[] memory _addresses)
        external
        view
        returns (uint256 networkValue, uint256 numberOfPools)
    {
        numberOfPools = _addresses.length;
        for (uint256 i = 0; i < numberOfPools; ++i) {
            (uint256 poolValue, ) = calcPoolValue(_addresses[i]);
            networkValue += poolValue;
        }
    }

    /*
     * INTERNAL FUNCTIONS
     */
    /// @dev Returns the price a pool from its id
    /// @param _poolAddress Address of the pool
    /// @return poolPrice Price of the pool in wei
    /// @return totalTokens Number of tokens of a pool (totalSupply)
    function getPoolPrice(address _poolAddress) internal view returns (uint256 poolPrice, uint256 totalTokens) {
        IPool poolInstance = IPool(_poolAddress);
        poolPrice = poolInstance.calcSharePrice();
        totalTokens = poolInstance.totalSupply();
    }

    /// @dev Returns the value of a pool and bool success.
    /// @param _poolAddress Address of the pool.
    /// @return aum Address of the target pool.
    /// @return success Address of the pool's group.
    function calcPoolValue(address _poolAddress) internal view returns (uint256 aum, bool success) {
        (uint256 price, uint256 supply) = getPoolPrice(_poolAddress);
        return (
            aum = ((price * supply) / 1000000), //1000000 is the base (6 decimals)
            success = true
        );
    }
}
