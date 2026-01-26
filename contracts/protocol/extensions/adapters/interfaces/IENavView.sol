// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {NavView} from "../../../libraries/NavView.sol";
import {AppTokenBalance} from "../../../types/ExternalApp.sol";

/// @title IENavView - Interface for the navigation and application view extension
/// @notice Provides view methods to retrieve token balances and NAV without modifying state
/// @dev Designed for off-chain queries like DeFiLlama, subgraphs, or ZK proof generation
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IENavView {
    /// @notice Returns complete NAV data for the pool
    /// @return navData Struct containing totalValue, unitaryValue, and timestamp
    function getNavDataView() external view returns (NavView.NavData memory navData);

    /// @notice Returns application token balances for external positions
    /// @return apps Array of AppTokenBalance structs with balances
    function getAppTokensAndBalancesView() external view returns (AppTokenBalance[] memory apps);
}
