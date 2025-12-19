// SPDX-License-Identifier: Apache-2.0-or-later
/*

 Copyright 2025 Rigo Intl.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.

*/

pragma solidity 0.8.28;

import {IENavView} from "./adapters/interfaces/IENavView.sol";
import {NavView} from "../libraries/NavView.sol";
import {StorageLib} from "../libraries/StorageLib.sol";
import {Applications} from "../types/Applications.sol";
import {ExternalApp} from "../types/ExternalApp.sol";

/// @title ENavView - Navigation and application view extension for Rigoblock smart pools
/// @notice Provides view methods to retrieve token balances and NAV without modifying state
/// @dev Designed as an extension to run via delegatecall in pool context for off-chain queries
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract ENavView is IENavView {
    /// @notice Address of the GRG staking proxy
    address public immutable grgStakingProxy;

    /// @notice Address of the Uniswap V4 position manager
    address public immutable uniV4Posm;

    /// @notice Constructor stores immutable addresses for chain-specific contracts
    /// @param _grgStakingProxy Address of the GRG staking proxy on this chain
    /// @param _uniV4Posm Address of the Uniswap V4 position manager on this chain
    /// @dev Different immutable addresses will result in different deployed addresses on different networks
    constructor(address _grgStakingProxy, address _uniV4Posm) {
        grgStakingProxy = _grgStakingProxy;
        uniV4Posm = _uniV4Posm;
    }

    /// @inheritdoc IENavView
    function getAppTokensAndBalancesView() public view override returns (ExternalApp[] memory apps) {
        return NavView.getAppTokenBalances(grgStakingProxy, uniV4Posm);
    }

    /// @inheritdoc IENavView
    function getAllTokensAndBalancesView() public view override returns (TokenBalance[] memory balances) {
        // Use NavView library to get all token balances
        NavView.TokenBalance[] memory navBalances = NavView.getTokensAndBalances(grgStakingProxy, uniV4Posm);
        
        // Convert NavView.TokenBalance to IENavView.TokenBalance
        balances = new TokenBalance[](navBalances.length);
        for (uint256 i = 0; i < navBalances.length; i++) {
            balances[i] = TokenBalance({
                token: navBalances[i].token,
                balance: navBalances[i].balance
            });
        }
    }

    /// @inheritdoc IENavView
    function getNavDataView() external view override returns (NavData memory navData) {
        // Use NavView library to get NAV data
        NavView.NavData memory navViewData = NavView.getNavData(grgStakingProxy, uniV4Posm);
        
        // Convert NavView.NavData to IENavView.NavData
        navData = NavData({
            totalValue: navViewData.totalValue,
            unitaryValue: navViewData.unitaryValue,
            timestamp: navViewData.timestamp
        });
    }
}