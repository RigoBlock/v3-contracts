// SPDX-License-Identifier: Apache-2.0-or-later

pragma solidity 0.8.28;

import {SlotDerivation} from "./SlotDerivation.sol";

/// @title VirtualBalanceLib - Library for managing per-token virtual balances
/// @notice Provides functions to get and set virtual balances for individual tokens
/// @dev Uses ERC-7201 namespaced storage pattern with per-token mappings
library VirtualBalanceLib {
    using SlotDerivation for bytes32;

    // TODO: check how we can use same as immutable constants without hardcoding here
    /// @notice Storage slot for per-token virtual balances (legacy slot)
    bytes32 private constant _VIRTUAL_BALANCES_SLOT =
        0x52fe1e3ba959a28a9d52ea27285aed82cfb0b6d02d0df76215ab2acc4b84d64f;

    /// @notice Storage slot for virtual supply (int256 to allow negative values)
    bytes32 private constant _VIRTUAL_SUPPLY_SLOT = 0xc1634c3ed93b1f7aa4d725c710ac3b239c1d30894404e630b60009ee3411450f;

    /// @notice Adjusts the virtual balance for a specific token
    /// @param token The token address
    /// @param delta The amount to add to the current virtual balance (can be negative)
    function adjustVirtualBalance(address token, int256 delta) internal {
        if (delta == 0) return;

        int256 currentBalance = getVirtualBalance(token);
        setVirtualBalance(token, currentBalance + delta);
    }

    /// @notice Adjusts the virtual supply by a delta amount
    /// @param delta The amount to add to the current virtual supply (can be negative)
    function adjustVirtualSupply(int256 delta) internal {
        if (delta == 0) return;

        int256 currentSupply = getVirtualSupply();
        setVirtualSupply(currentSupply + delta);
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

    /// @notice Sets the virtual supply
    /// @param value The virtual supply to set (can be negative)
    function setVirtualSupply(int256 value) internal {
        bytes32 slot = _VIRTUAL_SUPPLY_SLOT;
        assembly {
            sstore(slot, value)
        }
    }

    /// @notice Gets the virtual balance for a specific token
    /// @param token The token address
    /// @return value The virtual balance (can be negative)
    function getVirtualBalance(address token) internal view returns (int256 value) {
        bytes32 slot = _VIRTUAL_BALANCES_SLOT.deriveMapping(token);
        assembly {
            value := sload(slot)
        }
    }

    /// @notice Gets the virtual supply
    /// @return value The virtual supply (can be negative)
    function getVirtualSupply() internal view returns (int256 value) {
        bytes32 slot = _VIRTUAL_SUPPLY_SLOT;
        assembly {
            value := sload(slot)
        }
    }
}
