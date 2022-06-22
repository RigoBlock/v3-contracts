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

import { IAuthority as Authority } from "../interfaces/IAuthority.sol";
import { RigoblockPoolProxy } from "./RigoblockPoolProxy.sol";

/// @title RigoBlock Pool Factory library - Reduces size of pool factory.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
library RigoblockPoolProxyFactoryLibrary {

    struct NewPool {
        string name;
        string symbol;
        address owner;
        address newAddress;
    }

    /// @dev Allows an approved factory to create new pools
    /// @param _name String of the name
    /// @param _symbol String of the symbol
    /// @param _authority Address of the respective authority
    /// @return proxy Instance of a Rigoblock pool
    function createPool0(
        NewPool memory self,
        string memory _name,
        string memory _symbol,
        address _owner,
        address _authority)
        internal
        returns (RigoblockPoolProxy proxy)
    {
        proxy = new RigoblockPoolProxy(
            address(this),
            abi.encodeWithSelector(
                0xc9ee5905, // RigoblockPool._initializePool.selector
                // TODO: check gas saving in forwarding data as struct
                self.name = _name,
                self.symbol = _symbol,
                self.owner = _owner,
                _authority
            )
        );
        self.newAddress = address(proxy);
    }

    function createPool(
        NewPool memory self,
        string memory _name,
        string memory _symbol,
        address _owner,
        address _authority
    )
        internal
        returns (RigoblockPoolProxy proxy)
    {
        bytes memory encodedInitialization = abi.encodeWithSelector(
            0xc9ee5905, // RigoblockPool._initializePool.selector
            self.name = _name,
            self.symbol = _symbol,
            self.owner = _owner,
            _authority
        );
        bytes32 salt = keccak256(abi.encodePacked(_name, _symbol, _owner, msg.sender));
        bytes memory deploymentData = abi.encodePacked(
            type(RigoblockPoolProxy).creationCode, // bytecode
            abi.encode(
                uint256(uint160(address(this))), // beacon
                encodedInitialization // encoded initialization call
            )
        );
        assembly {
            proxy := create2(0x0, add(deploymentData, 0x20), mload(deploymentData), salt)
        }
        self.newAddress = address(proxy);
    }
}
