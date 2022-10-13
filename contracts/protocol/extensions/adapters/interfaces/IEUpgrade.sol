// SPDX-License-Identifier: Apache 2.0

pragma solidity >=0.8.0 <0.9.0;

interface IEUpgrade {
    /// @notice Emitted when pool operator upgrades proxy implementation address.
    /// @param implementation Address of the new implementation.
    event Upgraded(address indexed implementation);

    /// @notice Allows caller to upgrade pool implementation.
    /// @dev Cannot be called directly and in pool is restricted to pool owner.
    function upgradeImplementation() external;
}