// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.24;

import {SlotDerivation} from "../libraries/SlotDerivation.sol";
import {TransientSlot} from "../libraries/TransientSlot.sol";

type Int256 is bytes32;

library TransientBalance {
    using TransientSlot for *;
    using SlotDerivation for bytes32;

    // Helper functions for tstore operations
    /// @notice Stores a mapping of token addresses to int256 balances
    function store(Int256 slot, address token, int256 balance) internal {
        Int256.unwrap(slot).deriveMapping(token).asInt256().tstore(balance);
    }

    function get(Int256 slot, address token) internal view returns (int256) {
        return Int256.unwrap(slot).deriveMapping(token).asInt256().tload();
    }
}
