// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Applications} from "../../../types/Applications.sol";
import {AppTokenBalance, ExternalApp} from "../../../types/ExternalApp.sol";

/// @title IENavView - Interface for the navigation and application view extension
/// @notice Provides view methods to retrieve token balances and NAV without modifying state
/// @dev Designed for off-chain queries like DeFiLlama, subgraphs, or ZK proof generation
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IENavView {
    /// @notice Represents a token balance including virtual balances and application positions
    struct TokenBalance {
        address token;
        int256 balance; // Signed to support virtual balances and app positions
    }

    /// @notice Complete NAV data for a pool
    struct NavData {
        uint256 totalValue;    // Total pool value in base token
        uint256 unitaryValue;  // NAV per share
        uint256 timestamp;     // Block timestamp when calculated
    }

    /// @notice Returns all token balances including virtual balances and application positions
    /// @return balances Array of TokenBalance structs
    /// @dev This is not a view function because getAppTokenBalances uses transient storage.
    ///      Can still be called off-chain via eth_call for read-only queries.
    function getAllTokensAndBalancesView() external view returns (TokenBalance[] memory balances);

    /// @notice Returns complete NAV data for the pool
    /// @return navData Struct containing totalValue, unitaryValue, and timestamp
    function getNavDataView() external view returns (NavData memory navData);

    /// @notice Returns application token balances for external positions
    /// @return apps Array of ExternalApp structs with balances
    /// @dev Automatically determines which applications are active for this pool
    function getAppTokensAndBalancesView() external view returns (ExternalApp[] memory apps);
}