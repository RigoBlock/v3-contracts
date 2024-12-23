// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2024 Rigo Intl.

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

pragma solidity ^0.8.20;

// TODO: we could use the enumerable set from openzeppelin here, as we don't use tstore in this context. However,
// we should use that library, and overwrite with our own specifications, i.e. limit the max number of elements in the array.
// This way, we could use this library for pushing active addresses, tokenIds, and potentially more types without need to
// upgrade this library. This means we should overwrite all methods. Also add and remove are used in mint and purge in core,
// therefore library should be stable. Ideally we should keep those compact, so can avoid errors with upgrades, gas overhead
// of storing as bytes32 and reading as bytes32 is very small if compared to the gas used to decode transactions, or estimate nav.
// TODO: should add bytes32[] IdsSet for application positions, but should do so in a way that is extendable
library EnumerableSet {
    error AddressListLength();

    // limit size of array to prevent DOS to nav estimates
    uint256 private constant _MAX_UNIQUE_ADDRESSES = 255;

    // TODO: address(0) can be added as mapping to 0 is sentinel for not stored, while we can push a null element in the list
    struct AddressSet {
        // List of stored addresses
        address[] addresses;
        // Mapping of address to position.
        // Position 0 means an address has been removed.
        mapping(address => uint256) positions;
    }

    // TODO: verify what we have removed here, and also verify if can pass a max length to verify against
    function addUnique(Set storage set, address value) internal returns (bool) {
        require(set.params.length <= _MAX_UNIQUE_ADDRESSES, AddressListLength());
        if (!_contains(set, value)) {
            set.params.push(value);
            set.positions[value] = set.params.length;
            return true;
        } else {
            return false;
        }
    }

    function remove(Set storage set, address value) internal returns (bool) {
        uint256 position = set.positions[value];

        if (position != 0) {
            // Copy last element at index position and pop last element
            uint256 valueIndex = position - 1;
            uint256 lastIndex = set.params.length - 1;

            if (valueIndex != lastIndex) {
                bytes32 lastValue = set.addresses[lastIndex];

                // Move the lastValue to the index where the value to delete is
                set.addresses[valueIndex] = lastValue;
                // Update the tracked position of the lastValue (that was just moved)
                set.positions[lastValue] = position;
            }

            // Delete the slot where the moved value was stored
            set.params.pop();

            // Delete the tracked position for the deleted slot
            delete set.positions[value];

            return true;
        } else {
            return false;
        }
    }

    function _contains(Set storage set, address value) private view returns (bool) {
        return set.positions[value] != 0;
    }
}