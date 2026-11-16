// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {LighterViewData} from "../../../types/Applications.sol";

/// @title IEAppsLighter - LighterEVM-only extension interface.
interface IEAppsLighter {
    /// @notice Returns the pool's Lighter tracked markets and in-flight accounting.
    function getLighterTrackedMarkets() external view returns (LighterViewData memory viewData);
}
