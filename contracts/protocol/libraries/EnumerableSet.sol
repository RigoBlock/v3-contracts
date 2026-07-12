// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.28;

import {IEOracle} from "../extensions/adapters/interfaces/IEOracle.sol";
import {IPoolRegistry} from "../interfaces/IPoolRegistry.sol";
import {ISmartPoolEvents} from "../interfaces/v4/pool/ISmartPoolEvents.sol";

struct AddressSet {
    // List of stored addresses
    address[] addresses;
    // Mapping of address to position.
    // Position 0 means an address has never been added before.
    mapping(address token => uint256 position) positions;
}

struct Bytes32Set {
    // List of stored values
    bytes32[] values;
    // Mapping of value to position.
    // Position 0 means a value has never been added before.
    mapping(bytes32 value => uint256 position) positions;
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
    error PoolTokenNotAllowed(address token);

    // limit size of array to prevent DOS to nav estimates
    uint256 internal constant _MAX_UNIQUE_VALUES = type(uint8).max / 2; // max 128 values

    // flag for removed address
    uint256 private constant REMOVED_ADDRESS_FLAG = type(uint256).max;
    // flag for removed bytes32 value
    uint256 private constant REMOVED_BYTES32_FLAG = type(uint256).max;

    /// @notice Adds `token` to the set if it is not the base token and not already active.
    /// @dev Reads set.positions[token] exactly once. Returns whether the token was active
    ///  before this call (base token is always considered active and is never stored).
    function addUnique(
        AddressSet storage set,
        IEOracle eOracle,
        address token,
        address baseToken,
        address poolRegistry
    ) internal returns (bool wasActive) {
        if (token == baseToken) return true;

        uint256 position = set.positions[token]; // single SLOAD
        wasActive = (position != 0 && position != REMOVED_ADDRESS_FLAG);

        if (!wasActive) {
            require(set.addresses.length < _MAX_UNIQUE_VALUES, AddressListExceedsMaxLength());
            require(IPoolRegistry(poolRegistry).getPoolIdFromAddress(token) == bytes32(0), PoolTokenNotAllowed(token));
            require(eOracle.hasPriceFeed(token), TokenPriceFeedDoesNotExist(token));
            set.addresses.push(token);
            set.positions[token] = set.addresses.length;
            emit ISmartPoolEvents.TokenStatusChanged(token, true);
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

    function add(Bytes32Set storage set, bytes32 value) internal {
        if (set.positions[value] == 0 || set.positions[value] == REMOVED_BYTES32_FLAG) {
            require(set.values.length < _MAX_UNIQUE_VALUES, AddressListExceedsMaxLength());
            set.values.push(value);
            set.positions[value] = set.values.length;
        }
    }

    function remove(Bytes32Set storage set, bytes32 value) internal {
        uint256 position = set.positions[value];
        if (position != 0 && position != REMOVED_BYTES32_FLAG) {
            uint256 valueIndex = position - 1;
            uint256 lastIndex = set.values.length - 1;
            if (valueIndex != lastIndex) {
                bytes32 lastValue = set.values[lastIndex];
                set.values[valueIndex] = lastValue;
                set.positions[lastValue] = position;
            }
            set.values.pop();
            set.positions[value] = REMOVED_BYTES32_FLAG;
        }
    }

    function contains(Bytes32Set storage set, bytes32 value) internal view returns (bool) {
        uint256 position = set.positions[value];
        return position != 0 && position != REMOVED_BYTES32_FLAG;
    }

    function length(Bytes32Set storage set) internal view returns (uint256) {
        return set.values.length;
    }

    function at(Bytes32Set storage set, uint256 index) internal view returns (bytes32) {
        return set.values[index];
    }
}
