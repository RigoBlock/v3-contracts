// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {TokenIdsSlot} from "../types/Applications.sol";
import {ApplicationsSlot} from "./ApplicationsLib.sol";
import {AddressSet, Pool} from "./EnumerableSet.sol";

/// @notice A library for extensions to access proxy pre-assigned storage slots.
library StorageLib {
    /// @notice persistent storage slot, used to read from proxy storage without having to update implementation
    bytes32 private constant _POOL_INIT_SLOT = 0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8;
    bytes32 private constant _TOKEN_REGISTRY_SLOT = 0x3dcde6752c7421366e48f002bbf8d6493462e0e43af349bebb99f0470a12300d;
    bytes32 private constant _APPLICATIONS_SLOT = 0xdc487a67cca3fd0341a90d1b8834103014d2a61e6a212e57883f8680b8f9c831;

    /// @notice Storage expansion not declared in core immutables, but used by extensions and adapters.
    // bytes32(uint256(keccak256("pool.proxy.uniV4.tokenIds")) - 1)
    bytes32 private constant _UNIV4_TOKEN_IDS_SLOT = 0xd87266b00c1e82928c0b0200ad56e2ee648a35d4e9b273d2ac9533471e3b5d3c;

    function pool() internal pure returns (Pool storage s) {
        assembly {
            s.slot := _POOL_INIT_SLOT
        }
    }

    function activeTokensSet() internal pure returns (AddressSet storage s) {
        assembly {
            s.slot := _TOKEN_REGISTRY_SLOT
        }
    }

    function uniV4TokenIdsSlot() internal pure returns (TokenIdsSlot storage s) {
        assembly {
            s.slot := _UNIV4_TOKEN_IDS_SLOT 
        }
    }

    function activeApplications() internal pure returns (ApplicationsSlot storage s) {
        assembly {
            s.slot := _APPLICATIONS_SLOT
        }
    }
}
