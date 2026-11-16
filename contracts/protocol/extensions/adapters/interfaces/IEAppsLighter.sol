// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

/// @title IEAppsLighter - LighterEVM-only extension interface.
interface IEAppsLighter {
    /// @notice Returns the pool's tracked Lighter perp market ids.
    function getLighterTrackedMarkets() external view returns (uint16[] memory marketIds);
}
