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

import { IPool } from "../../utils/pool/IPool.sol";
import { IPoolRegistry } from "../../protocol/interfaces/IPoolRegistry.sol";

/// @title Network - Returns data of active pools and network value.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract Network {

    address public POOLREGISTRYADDRESS;

    constructor(
        address poolRegistryAddress)
    {
        POOLREGISTRYADDRESS = poolRegistryAddress;
    }

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    /// @dev Returns two arrays of prices and total supply
    /// @return poolAddresses Array of addressed of the active pools
    /// @return poolPrices Array of the prices of the active pools
    /// @return totalTokens Array of the number of tokens of each pool
    function getPoolsPrices(bytes32[] memory _ids)
        external view
        returns (
            address[] memory,
            uint256[] memory,
            uint256[] memory
        )
    {
        uint256 length = _ids.length;
        address[] memory poolAddresses = new address[](length);
        uint256[] memory poolPrices = new uint256[](length);
        uint256[] memory totalTokens = new uint256[](length);
        for (uint256 i = 0; i < length; ++i) {
            bool active = isActive(uint256(_ids[i]));
            if (!active) {
                continue;
            }
            (poolAddresses[uint256(_ids[i])], ) = addressFromId(uint256(_ids[i]));
            IPool poolInstance = IPool(poolAddresses[uint256(_ids[i])]);
            poolPrices[uint256(_ids[i])] = poolInstance.calcSharePrice();
            totalTokens[uint256(_ids[i])] = poolInstance.totalSupply();
        }
        return (
            poolAddresses,
            poolPrices,
            totalTokens
        );
    }

    /// @dev Returns the value of the assets in the rigoblock network
    /// @return networkValue alue of the rigoblock network in wei
    /// @return numberOfPools Number of active funds
    function calcNetworkValue(bytes32[] memory _ids)
        external
        view
        returns (
            uint256 networkValue,
            uint256 numberOfPools
        )
    {
        numberOfPools = _ids.length;
        for (uint256 i = 0; i < numberOfPools; ++i) {
            bool active = isActive(uint256(_ids[i]));
            if (!active) {
                continue;
            }
            (uint256 poolValue, ) = calcPoolValue(uint256(_ids[i]));
            networkValue += poolValue;
        }
    }


    /*
     * INTERNAL FUNCTIONS
     */
    /// @dev Checks whether a pool is registered and active
    /// @param poolId Id of the pool
    /// @return Bool the pool is active
    function isActive(uint256 poolId)
        internal view
        returns (bool)
    {
        (address poolAddress, , ) = IPoolRegistry(POOLREGISTRYADDRESS).fromId(poolId);
        if (poolAddress != address(0)) {
            return true;
        } else return false;
    }

    /// @dev Returns the address and the group of a pool from its id
    /// @param poolId Id of the pool
    /// @return poolAddress Address of the target pool
    /// @return groupAddress Address of the pool's group
    function addressFromId(uint256 poolId)
        internal view
        returns (
            address poolAddress,
            address groupAddress
        )
    {
        (poolAddress, , groupAddress) = IPoolRegistry(POOLREGISTRYADDRESS).fromId(poolId);
    }

    /// @dev Returns the price a pool from its id
    /// @param poolId Id of the pool
    /// @return poolPrice Price of the pool in wei
    /// @return totalTokens Number of tokens of a pool (totalSupply)
    function getPoolPrice(uint256 poolId)
        internal view
        returns (
            uint256 poolPrice,
            uint256 totalTokens
        )
    {
        (address poolAddress, ) = addressFromId(poolId);
        IPool poolInstance = IPool(poolAddress);
        poolPrice = poolInstance.calcSharePrice();
        totalTokens = poolInstance.totalSupply();
    }

    /// @dev Returns the address and the group of a pool from its id
    /// @param poolId Id of the pool
    /// @return aum Address of the target pool
    /// @return success Address of the pool's group
    function calcPoolValue(uint256 poolId)
        internal view
        returns (
            uint256 aum,
            bool success
        )
    {
        (uint256 price, uint256 supply) = getPoolPrice(poolId);
        return (
            aum = (price * supply / 1000000), //1000000 is the base (6 decimals)
            success = true
        );
    }
}
