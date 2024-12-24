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

struct AddressSet {
    // List of stored addresses
    address[] addresses;
    // Mapping of address to position.
    // Position 0 means an address has been removed.
    mapping(address => uint256) positions;
}

library EnumerableSet {
    error AddressListLength();

    // limit size of array to prevent DOS to nav estimates
    uint256 private constant _MAX_UNIQUE_ADDRESSES = 255;

    function addUnique(AddressSet storage set, address value) internal returns (bool) {
        require(set.addresses.length <= _MAX_UNIQUE_ADDRESSES, AddressListLength());
        if (!_contains(set, value)) {
            set.addresses.push(value);
            set.positions[value] = set.addresses.length;
            return true;
        } else {
            return false;
        }
    }

    function remove(AddressSet storage set, address value) internal returns (bool) {
        uint256 position = set.positions[value];

        if (position != 0) {
            // Copy last element at index position and pop last element
            uint256 valueIndex = position - 1;
            uint256 lastIndex = set.addresses.length - 1;

            if (valueIndex != lastIndex) {
                address lastValue = set.addresses[lastIndex];

                // Move the lastValue to the index where the value to delete is
                set.addresses[valueIndex] = lastValue;
                // Update the tracked position of the lastValue (that was just moved)
                set.positions[lastValue] = position;
            }

            // Delete the slot where the moved value was stored
            set.addresses.pop();

            // Delete the tracked position for the deleted slot
            delete set.positions[value];

            return true;
        } else {
            return false;
        }
    }

    function _contains(AddressSet storage set, address value) private view returns (bool) {
        return set.positions[value] != 0;
    }
}