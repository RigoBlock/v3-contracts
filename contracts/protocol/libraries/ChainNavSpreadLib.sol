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

/// @title ChainNavSpreadLib - Library for managing NAV spreads between chains
/// @notice Provides functions to get and set NAV spreads for cross-chain synchronization
/// @dev Uses ERC-7201 namespaced storage pattern with per-chain mappings
library ChainNavSpreadLib {
    using SlotDerivation for bytes32;

    /// @notice Storage slot for chain NAV spreads
    bytes32 private constant _CHAIN_NAV_SPREADS_SLOT =
        0x1effae8a79ec0c3b88754a639dc07316aa9c4de89b6b9794fb7c1d791c43492d;

    /// @notice Gets the NAV spread for a specific chain
    /// @param chainId The chain ID
    /// @return spread The NAV spread (can be negative)
    function getChainNavSpread(uint256 chainId) internal view returns (int256 spread) {
        bytes32 slot = _CHAIN_NAV_SPREADS_SLOT.deriveMapping(bytes32(chainId));
        assembly {
            spread := sload(slot)
        }
    }

    /// @notice Sets the NAV spread for a specific chain
    /// @param chainId The chain ID
    /// @param spread The NAV spread to set (can be negative)
    function setChainNavSpread(uint256 chainId, int256 spread) internal {
        bytes32 slot = _CHAIN_NAV_SPREADS_SLOT.deriveMapping(bytes32(chainId));
        assembly {
            sstore(slot, spread)
        }
    }

    /// @notice Checks if a chain has a recorded NAV spread
    /// @param chainId The chain ID
    /// @return hasSpread True if the chain has a recorded spread
    function hasChainNavSpread(uint256 chainId) internal view returns (bool hasSpread) {
        return getChainNavSpread(chainId) != 0;
    }

    /// @notice Resets the NAV spread for a chain to zero
    /// @param chainId The chain ID
    function clearChainNavSpread(uint256 chainId) internal {
        setChainNavSpread(chainId, 0);
    }
}