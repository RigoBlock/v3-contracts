// SPDX-License-Identifier: Apache-2.0-or-later
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

pragma solidity 0.8.28;

import {SlotDerivation} from "./SlotDerivation.sol";

/// @title VirtualBalanceLib - Library for managing per-token virtual balances
/// @notice Provides functions to get and set virtual balances for individual tokens
/// @dev Uses ERC-7201 namespaced storage pattern with per-token mappings
library VirtualBalanceLib {
    using SlotDerivation for bytes32;

    /// @notice Storage slot for per-token virtual balances (legacy slot)
    bytes32 private constant _VIRTUAL_BALANCES_SLOT = 
        0x52fe1e3ba959a28a9d52ea27285aed82cfb0b6d02d0df76215ab2acc4b84d64f;

    /// @notice Gets the virtual balance for a specific token
    /// @param token The token address
    /// @return value The virtual balance (can be negative)
    function getVirtualBalance(address token) internal view returns (int256 value) {
        bytes32 slot = _VIRTUAL_BALANCES_SLOT.deriveMapping(token);
        assembly {
            value := sload(slot)
        }
    }

    /// @notice Sets the virtual balance for a specific token
    /// @param token The token address
    /// @param value The virtual balance to set (can be negative)
    function setVirtualBalance(address token, int256 value) internal {
        bytes32 slot = _VIRTUAL_BALANCES_SLOT.deriveMapping(token);
        assembly {
            sstore(slot, value)
        }
    }

    /// @notice Adjusts the virtual balance for a specific token
    /// @param token The token address
    /// @param delta The amount to add to the current virtual balance (can be negative)
    function adjustVirtualBalance(address token, int256 delta) internal {
        if (delta == 0) return;
        
        int256 currentBalance = getVirtualBalance(token);
        setVirtualBalance(token, currentBalance + delta);
    }

    /// @notice Checks if a token has any virtual balance
    /// @param token The token address
    /// @return hasBalance True if the token has a non-zero virtual balance
    function hasVirtualBalance(address token) internal view returns (bool hasBalance) {
        return getVirtualBalance(token) != 0;
    }

    /// @notice Resets the virtual balance for a token to zero
    /// @param token The token address
    function clearVirtualBalance(address token) internal {
        setVirtualBalance(token, 0);
    }
}