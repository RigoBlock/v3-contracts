// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

interface IMinimumVersion {
    /// @notice Returns the minimum implementation version to use an external application.
    /// @dev Adapters must implement it when modifying proxy state or storage.
    /// @return String of the minimum supported version.
    function requiredVersion() external view returns (string memory);
}
