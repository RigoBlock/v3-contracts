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

import {IEOracle} from "../extensions/adapters/interfaces/IEOracle.sol";

struct AddressSet {
    // List of stored addresses
    address[] addresses;
    // Mapping of address to position.
    // Position 0 means an address has never been added before.
    mapping(address => uint256) positions;
}

library EnumerableSet {
    error AddressListExceedsMaxLength();
    error TokenPriceFeedDoesNotExist(address token);

    // limit size of array to prevent DOS to nav estimates
    uint256 private constant _MAX_UNIQUE_ADDRESSES = type(uint8).max;

    // flag for removed address
    uint256 private constant _REMOVED_ADDRESS_FLAG = type(uint256).max;

    // TODO: check if should log, even though we already store in list so not strictly needed.
    /// @notice Base token is never pushed to active tokens, as already stored.
    function addUnique(AddressSet storage set, IEOracle oracle, address value, address baseToken) internal {
        if (value != baseToken) {
            if (set.positions[value] == 0 || set.positions[value] == _REMOVED_ADDRESS_FLAG) {
                require(set.addresses.length < _MAX_UNIQUE_ADDRESSES, AddressListExceedsMaxLength());

                // perform a staticcall to the oracle extension and assert new token has a price feed. Removed token as well
                require(oracle.hasPriceFeed(value), TokenPriceFeedDoesNotExist(value));

                // update storage
                set.addresses.push(value);
                set.positions[value] = set.addresses.length;
            }
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

            // Delete the tracked position for the deleted slot without clearing storage
            set.positions[value] = _REMOVED_ADDRESS_FLAG;

            return true;
        } else {
            return false;
        }
    }
}