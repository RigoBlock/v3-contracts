// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.24;

import {SlotDerivation} from "./SlotDerivation.sol";
import {TransientSlot} from "./TransientSlot.sol";

type Int256 is bytes32;

library TransientStorage {
    using TransientSlot for *;
    using SlotDerivation for bytes32;

    bytes32 internal constant _TRANSIENT_BALANCE_SLOT =
        bytes32(uint256(keccak256("mixin.value.transient.balance")) - 1);

    bytes32 internal constant _TRANSIENT_TWAP_TICK_SLOT = bytes32(uint256(keccak256("transient.tick.slot")) - 1);

    // Helper functions for tstore operations
    /// @notice Stores a mapping of token addresses to int256 values
    function store(Int256 slot, address token, int256 value) internal {
        Int256.unwrap(slot).deriveMapping(token).asInt256().tstore(value);
    }

    function get(Int256 slot, address token) internal view returns (int256) {
        return Int256.unwrap(slot).deriveMapping(token).asInt256().tload();
    }

    function storeBalance(address token, int256 balance) internal {
        store(Int256.wrap(_TRANSIENT_BALANCE_SLOT), token, balance);
    }

    function getBalance(address token) internal view returns (int256) {
        return get(Int256.wrap(_TRANSIENT_BALANCE_SLOT), token);
    }

    function storeTwap(address token, int24 twap) internal {
        store(Int256.wrap(_TRANSIENT_TWAP_TICK_SLOT), token, int256(twap));
    }

    function getTwap(address token) internal view returns (int24) {
        return int24(get(Int256.wrap(_TRANSIENT_TWAP_TICK_SLOT), token));
    }
}
