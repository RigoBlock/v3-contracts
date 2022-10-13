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

pragma solidity 0.8.17;

import "./adapters/interfaces/IEUpgrade.sol";
import {IRigoblockPoolProxyFactory as Beacon} from "../interfaces/IRigoblockPoolProxyFactory.sol";
import "../../utils/storageSlot/StorageSlot.sol";

/// @title EUpgrade - Allows upgrading implementation.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract EUpgrade is IEUpgrade {
    address private immutable _eUpgrade;
    address private immutable _factory;

    constructor(address factory) {
        _eUpgrade = address(this);
        _factory = factory;
    }

    /// @inheritdoc IEUpgrade
    function upgradeImplementation() external override {
        // prevent direct calls to this contract
        require(_eUpgrade != address(this), "EUPGRADE_DIRECT_CALL_ERROR");

        // read implementation address from factory. Different factories may have different implementations.
        // implementation will always be a contract as factory asserts that.
        address newImplementation = Beacon(getBeacon()).implementation();

        // we define the storage area where we will write new implementation as the eip1967 implementation slot
        bytes32 implementationSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assert(implementationSlot == bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1));

        // we read the current implementation address from the pool proxy storage
        address currentImplementation = StorageSlot.getAddressSlot(implementationSlot).value;

        // transaction reverted if implementation is same as current
        require(newImplementation != currentImplementation, "EUPGRADE_IMPLEMENTATION_SAME_AS_CURRENT_ERROR");

        // we write new address to storage at implementation slot location and emit eip1967 log
        StorageSlot.getAddressSlot(implementationSlot).value = newImplementation;
        emit Upgraded(newImplementation);
    }

    function getBeacon() public view returns (address) {
        return _factory;
    }

    function _isContract(address _target) private view returns (bool) {
        return _target.code.length > 0;
    }
}