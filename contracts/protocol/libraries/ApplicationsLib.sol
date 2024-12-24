// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.24;

struct ApplicationsSlot {
    uint256 packedApplications;
}

library ApplicationsLib {
    error ApplicationIndexBitmaskRange();

    uint256 private constant MAX_ALLOWED_APPLICATIONS = 31;

    /// @notice Sets an application as active in the bitmask.
    /// @param self The storage slot where the packed applications are stored.
    /// @param appIndex The application to set as active.
    function storeApplication(ApplicationsSlot storage self, uint256 appIndex) internal {
        require(appIndex < MAX_ALLOWED_APPLICATIONS, ApplicationIndexBitmaskRange());
        uint256 flag = 1 << appIndex;
        self.packedApplications |= flag;
    }

    /// @notice Removes an application from being active in the bitmask.
    /// @param self The storage slot where the packed applications are stored.
    /// @param appIndex The application to remove.
    function removeApplication(ApplicationsSlot storage self, uint256 appIndex) internal {
        require(appIndex < MAX_ALLOWED_APPLICATIONS, ApplicationIndexBitmaskRange());
        uint256 flag = ~(1 << appIndex);
        self.packedApplications &= flag;
    }

    /// @notice Checks if an application is active in the bitmask.
    /// @param packedApplications The bitmap packed active applications flags.
    /// @param appIndex The application to check.
    /// @return bool Whether the application is active.
    function isActiveApplication(uint256 packedApplications, uint256 appIndex) internal pure returns (bool) {
        require(appIndex < MAX_ALLOWED_APPLICATIONS, ApplicationIndexBitmaskRange());
        uint256 flag = 1 << appIndex;
        return (packedApplications & flag) != 0;
    }
}