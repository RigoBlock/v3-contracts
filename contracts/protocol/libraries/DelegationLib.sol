// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.28;

/// @notice Per-pool delegated-access state stored at a dedicated ERC-7201 slot.
/// @dev Four parallel data structures maintain two enumerable mappings:
///      selector → [delegated addresses]  (for revoke-by-selector)
///      address  → [delegated selectors]  (for revoke-by-address)
///      Both directions are kept in O(1) via position tracking (1-indexed, 0 = absent).
struct DelegationData {
    /// @dev selector → (address → 1-indexed position in selectorAddresses[selector]). 0 = not delegated.
    mapping(bytes4 => mapping(address => uint256)) selectorToAddressPosition;
    /// @dev selector → ordered list of delegated addresses.
    mapping(bytes4 => address[]) selectorAddresses;
    /// @dev address → ordered list of selectors delegated to it.
    mapping(address => bytes4[]) addressSelectors;
    /// @dev address → (selector → 1-indexed position in addressSelectors[address]). 0 = not present.
    mapping(address => mapping(bytes4 => uint256)) addressToSelectorPosition;
}

/// @title DelegationLib - Enumerable bi-directional delegation registry.
/// @notice Library for managing granular per-selector delegated write access to pool adapters.
/// @dev All writes maintain two enumerable index structures so callers can enumerate delegations
///      in either direction without iterating unpredictably large arrays.
library DelegationLib {
    // -------------------------------------------------------------------------
    // Mutating operations
    // -------------------------------------------------------------------------

    /// @notice Grants delegated write access to `selector` for `addr`.
    /// @return added True if the pair was newly granted (false = already existed, no storage change).
    function add(DelegationData storage self, bytes4 selector, address addr) internal returns (bool added) {
        if (self.selectorToAddressPosition[selector][addr] != 0) return false;

        // Register in selector → addresses direction
        self.selectorAddresses[selector].push(addr);
        self.selectorToAddressPosition[selector][addr] = self.selectorAddresses[selector].length; // 1-indexed

        // Register in address → selectors direction
        self.addressSelectors[addr].push(selector);
        self.addressToSelectorPosition[addr][selector] = self.addressSelectors[addr].length; // 1-indexed

        return true;
    }

    /// @notice Revokes delegated write access to `selector` for `addr`.
    /// @return removed True if the pair was present and removed (false = was not delegated, no storage change).
    function remove(DelegationData storage self, bytes4 selector, address addr) internal returns (bool removed) {
        uint256 posInSelector = self.selectorToAddressPosition[selector][addr];
        if (posInSelector == 0) return false;

        // Swap-and-pop from selectorAddresses[selector]
        address[] storage addrList = self.selectorAddresses[selector];
        uint256 lastIdx = addrList.length - 1;
        uint256 removeIdx = posInSelector - 1;

        if (removeIdx != lastIdx) {
            address lastAddr = addrList[lastIdx];
            addrList[removeIdx] = lastAddr;
            self.selectorToAddressPosition[selector][lastAddr] = posInSelector;
        }
        addrList.pop();
        delete self.selectorToAddressPosition[selector][addr];

        // Swap-and-pop from addressSelectors[addr]
        uint256 posInAddr = self.addressToSelectorPosition[addr][selector];
        bytes4[] storage selList = self.addressSelectors[addr];
        uint256 lastSel = selList.length - 1;
        uint256 removeSelIdx = posInAddr - 1;

        if (removeSelIdx != lastSel) {
            bytes4 lastSelector = selList[lastSel];
            selList[removeSelIdx] = lastSelector;
            self.addressToSelectorPosition[addr][lastSelector] = posInAddr;
        }
        selList.pop();
        delete self.addressToSelectorPosition[addr][selector];

        return true;
    }

    /// @notice Revokes all delegations previously granted to `addr` (e.g. compromised wallet).
    /// @dev Iterates the (short) list of selectors for addr and cleans up both directions.
    function removeAllByAddress(DelegationData storage self, address addr) internal {
        bytes4[] storage selectors = self.addressSelectors[addr];
        uint256 len = selectors.length;

        for (uint256 i = 0; i < len; ++i) {
            bytes4 sel = selectors[i];

            // Remove addr from selectorAddresses[sel] via swap-and-pop
            uint256 posInSelector = self.selectorToAddressPosition[sel][addr];
            address[] storage addrList = self.selectorAddresses[sel];
            uint256 lastIdx = addrList.length - 1;
            uint256 removeIdx = posInSelector - 1;

            if (removeIdx != lastIdx) {
                address lastAddr = addrList[lastIdx];
                addrList[removeIdx] = lastAddr;
                self.selectorToAddressPosition[sel][lastAddr] = posInSelector;
            }
            addrList.pop();
            delete self.selectorToAddressPosition[sel][addr];
            delete self.addressToSelectorPosition[addr][sel];
        }

        delete self.addressSelectors[addr];
    }

    /// @notice Revokes all delegations for `selector` (e.g. adapter being replaced by governance).
    /// @dev Iterates the (short) list of addresses for selector and cleans up both directions.
    function removeAllBySelector(DelegationData storage self, bytes4 selector) internal {
        address[] storage addrs = self.selectorAddresses[selector];
        uint256 len = addrs.length;

        for (uint256 i = 0; i < len; ++i) {
            address addr = addrs[i];

            // Remove selector from addressSelectors[addr] via swap-and-pop
            uint256 posInAddr = self.addressToSelectorPosition[addr][selector];
            bytes4[] storage selList = self.addressSelectors[addr];
            uint256 lastSel = selList.length - 1;
            uint256 removeSel = posInAddr - 1;

            if (removeSel != lastSel) {
                bytes4 lastSelector = selList[lastSel];
                selList[removeSel] = lastSelector;
                self.addressToSelectorPosition[addr][lastSelector] = posInAddr;
            }
            selList.pop();
            delete self.addressToSelectorPosition[addr][selector];
            delete self.selectorToAddressPosition[selector][addr];
        }

        delete self.selectorAddresses[selector];
    }

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    /// @notice Returns whether `addr` has been granted delegated write access to `selector`.
    function isDelegated(DelegationData storage self, bytes4 selector, address addr) internal view returns (bool) {
        return self.selectorToAddressPosition[selector][addr] != 0;
    }

    /// @notice Returns all addresses currently delegated for `selector`.
    function getAddresses(DelegationData storage self, bytes4 selector) internal view returns (address[] memory) {
        return self.selectorAddresses[selector];
    }

    /// @notice Returns all selectors currently delegated to `addr`.
    function getSelectors(DelegationData storage self, address addr) internal view returns (bytes4[] memory) {
        return self.addressSelectors[addr];
    }
}
