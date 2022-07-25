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

    event Upgraded(address indexed implementation);

    event RegistryUpgraded(address indexed registry);

    /*
     * STORAGE
     */
    /// @dev Returns the implementation address for the pool proxies.
    /// @return Address of the implementation.
    function implementation() external view returns (address);

    /*
     * PUBLIC FUNCTIONS
     */
    /// @dev Creates a new Rigoblock pool.
    /// @param _name String of the name.
    /// @param _symbol String of the symbol.
    /// @param _baseToken Address of the base token.
    /// @return newPoolAddress Address of the new pool.
    /// @return poolId Id of the new pool.
    function createPool(
        string calldata _name,
        string calldata _symbol,
        address _baseToken
    )
        external
        returns (address newPoolAddress, bytes32 poolId);

    /// @dev Allows owner to update the registry.
    /// @param _newRegistry Address of the new registry.
    function setRegistry(address _newRegistry)
        external;

    function setImplementation(address _newImplementation)
        external;

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    /// @dev Returns the address of the pool registry.
    /// @return Address of the registry.
    function getRegistry()
        external
        view
        returns (address);
}
