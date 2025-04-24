// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

library StorageSlot {
    struct AddressSlot {
        address value;
    }

    function getAddressSlot(bytes32 slot) internal pure returns (AddressSlot storage r) {
        assembly {
            r.slot := slot
        }
    }
}
