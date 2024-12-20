// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.24;

// TODO: verify this is the correct import, and if should import from types
import {ApplicationsSlot} from "../interfaces/pool/IRigoblockV3PoolState.sol"

library ApplicationsLib {
    error ApplicationIndexBitmaskRange();

    /// @notice Sets an application as active in the bitmask
    /// @param self The storage slot where the packed applications are stored
    /// @param appIndex The application to set as active
    function storeApplication(ApplicationsSlot storage self, uint256 appIndex) internal {
        require(appIndex < 256, ApplicationIndexBitmaskRange());
        uint256 flag = 1 << appIndex;
        self.packedApplications |= flag;
    }

    /// @notice Removes an application from being active in the bitmask
    /// @param self The storage slot where the packed applications are stored
    /// @param appIndex The application to remove
    function removeApplication(ApplicationsSlot storage self, uint256 appIndex) internal {
        require(appIndex < 256, ApplicationIndexBitmaskRange());
        uint256 flag = ~(1 << appIndex);
        self.packedApplications &= flag;
    }

    /// @notice Checks if an application is active in the bitmask
    /// @param packed The stored packed active applications
    /// @param appIndex The application to check
    /// @return bool Whether the application is active
    function isActiveApplication(uint256 packed, uint256 appIndex) internal view returns (bool) {
        require(appIndex < 256, ApplicationIndexBitmaskRange());
        uint256 flag = 1 << appIndex;
        return (packed & app) != 0;
    }
}