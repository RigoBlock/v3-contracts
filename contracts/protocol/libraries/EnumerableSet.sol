// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2025 Rigo Intl.

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

pragma solidity ^0.8.28;

import {IEOracle} from "../extensions/adapters/interfaces/IEOracle.sol";
import {ISmartPoolEvents} from "../interfaces/v4/pool/ISmartPoolEvents.sol";

struct AddressSet {
    // List of stored addresses
    address[] addresses;
    // Mapping of address to position.
    // Position 0 means an address has never been added before.
    mapping(address => uint256) positions;
}

/// @notice Pool initialization parameters.
/// @dev This struct is not visible externally and used to store/read pool init params.
/// @param name String of the pool name (max 32 characters).
/// @param symbol Bytes8 of the pool symbol (from 3 to 5 characters).
/// @param decimals Uint8 decimals.
/// @param owner Address of the pool operator.
/// @param unlocked Boolean the pool is locked for reentrancy check.
/// @param baseToken Address of the base token of the pool (0 for base currency).
struct Pool {
    string name;
    bytes8 symbol;
    uint8 decimals;
    address owner;
    bool unlocked;
    address baseToken;
}

/// @notice Adapted from https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/structs/EnumerableSet.sol
library EnumerableSet {
    error AddressListExceedsMaxLength();
    error TokenPriceFeedDoesNotExist(address token);

    // limit size of array to prevent DOS to nav estimates
    uint256 internal constant _MAX_UNIQUE_VALUES = type(uint8).max / 2; // max 128 values

    // flag for removed address
    uint256 private constant REMOVED_ADDRESS_FLAG = type(uint256).max;

    /// @notice Base token is never pushed to active tokens, as already stored.
    /// @dev Skips and returns false for base token, which is already in storage.
    function addUnique(AddressSet storage set, IEOracle eOracle, address token, address baseToken) internal {
        if (token != baseToken) {
            if (set.positions[token] == 0 || set.positions[token] == REMOVED_ADDRESS_FLAG) {
                require(set.addresses.length < _MAX_UNIQUE_VALUES, AddressListExceedsMaxLength());

                // perform a staticcall to the oracle extension and assert token has a price feed
                require(eOracle.hasPriceFeed(token), TokenPriceFeedDoesNotExist(token));

                // update storage
                set.addresses.push(token);
                set.positions[token] = set.addresses.length;

                // emit event for token activation
                emit ISmartPoolEvents.TokenStatusChanged(token, true);
            }
        }
    }

    function remove(AddressSet storage set, address token) internal {
        uint256 position = set.positions[token];

        if (position != 0 && position != REMOVED_ADDRESS_FLAG) {
            // Copy last element at position and pop last element
            uint256 addressIndex = position - 1;
            uint256 lastIndex = set.addresses.length - 1;

            if (addressIndex != lastIndex) {
                address lastAddress = set.addresses[lastIndex];

                // Move the lastToken to the index where the token to delete is
                set.addresses[addressIndex] = lastAddress;
                // Update the tracked position of the lastToken (that was just moved)
                set.positions[lastAddress] = position;
            }

            // Delete the slot where the moved token was stored
            set.addresses.pop();

            // Delete the tracked position for the deleted slot without clearing storage
            set.positions[token] = REMOVED_ADDRESS_FLAG;

            // emit event for token deactivation
            emit ISmartPoolEvents.TokenStatusChanged(token, false);
            return;
        }
    }

    function isActive(AddressSet storage set, address token) internal view returns (bool) {
        uint256 position = set.positions[token];
        return (position != 0 && position != REMOVED_ADDRESS_FLAG);
    }
}
