// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

interface IGovernanceInitializer {
    /// @notice Initializes the Rigoblock Governance.
    /// @dev Params are stored in factory and read from there.
    function initializeGovernance() external;
}
