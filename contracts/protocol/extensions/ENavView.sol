// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {IENavView} from "./adapters/interfaces/IENavView.sol";
import {ISmartPool} from "../ISmartPool.sol";
import {NavView} from "../libraries/NavView.sol";
import {StorageLib} from "../libraries/StorageLib.sol";
import {Applications} from "../types/Applications.sol";
import {AppTokenBalance} from "../types/ExternalApp.sol";

/// @title ENavView - Navigation and application view extension for Rigoblock smart pools
/// @notice Provides view methods to retrieve token balances and NAV without modifying state
/// @dev Designed as an extension to run via delegatecall in pool context for off-chain queries
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract ENavView is IENavView {
    /// @notice Address of the GRG staking proxy
    address private immutable grgStakingProxy;

    /// @notice Address of the Uniswap V4 position manager
    address private immutable uniV4Posm;

    /// @notice Constructor stores immutable addresses for chain-specific contracts
    /// @param _grgStakingProxy Address of the GRG staking proxy on this chain
    /// @param _uniV4Posm Address of the Uniswap V4 position manager on this chain
    constructor(address _grgStakingProxy, address _uniV4Posm) {
        grgStakingProxy = _grgStakingProxy;
        uniV4Posm = _uniV4Posm;
    }

    /// @inheritdoc IENavView
    function getAppTokensAndBalancesView() external view override returns (AppTokenBalance[] memory balances) {
        return NavView.getAppTokenBalances(grgStakingProxy, uniV4Posm);
    }

    /// @inheritdoc IENavView
    function getNavDataView() external view override returns (NavView.NavData memory navData) {
        return NavView.getNavData(grgStakingProxy, uniV4Posm);
    }
}
