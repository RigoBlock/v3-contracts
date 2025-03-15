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

import {MixinOwnerActions} from "../actions/MixinOwnerActions.sol";
import {IEApps} from "../../extensions/adapters/interfaces/IEApps.sol";
import {IEOracle} from "../../extensions/adapters/interfaces/IEOracle.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {AddressSet, EnumerableSet} from "../../libraries/EnumerableSet.sol";
import {ApplicationsLib, ApplicationsSlot} from "../../libraries/ApplicationsLib.sol";
import {TransientStorage} from "../../libraries/TransientStorage.sol";
import {ExternalApp} from "../../types/ExternalApp.sol";
import {NavComponents} from "../../types/NavComponents.sol";

// TODO: check make catastrophic failure resistant, i.e. must always be possible to liquidate pool + must always
//  use base token balances. If cannot guarantee base token balances can be retrieved, pointless and can be implemented in extension.
//  General idea is if the component is simple and not requires revisit of logic, implement as library, otherwise
//  implement as extension.
abstract contract MixinPoolValue is MixinOwnerActions {
    using ApplicationsLib for ApplicationsSlot;
    using EnumerableSet for AddressSet;
    using TransientStorage for address;

    error BaseTokenPriceFeedError();

    // TODO: assert not possible to inflate total supply to manipulate pool price.
    /// @notice Uses transient storage to keep track of unique token balances.
    /// @dev With null total supply a pool will return the last stored value.
    function _updateNav() internal override returns (NavComponents memory components) {
        components.unitaryValue = poolTokens().unitaryValue;
        components.totalSupply = poolTokens().totalSupply;
        components.baseToken = pool().baseToken;
        components.decimals = pool().decimals;

        // first mint skips nav calculation
        if (components.unitaryValue == 0) {
            components.unitaryValue = 10 ** components.decimals;
        } else if (components.totalSupply == 0) {
            return components;
        } else {
            uint256 totalPoolValue = _computeTotalPoolValue(components.baseToken);

            // TODO: verify under what scenario totalPoolValue would be null here
            if (totalPoolValue > 0) {
                // TODO: verify why we missed decimals rescaling
                // unitary value needs to be scaled by pool decimals (same as base token decimals)
                components.unitaryValue = totalPoolValue * 10 ** components.decimals / components.totalSupply;
            } else {
                return components;
            }
        }

        // unitary value cannot be null
        assert(components.unitaryValue > 0);

        // update storage only if different
        if (components.unitaryValue != poolTokens().unitaryValue) {
            poolTokens().unitaryValue = components.unitaryValue;
            emit NewNav(msg.sender, address(this), components.unitaryValue);
        }
    }

    /// @notice Updates the stored value with an updated one.
    /// @param baseToken The address of the base token.
    /// @return poolValue The total value of the pool in base token units.
    /// @dev Assumes the stored list contain unique elements.
    /// @dev A write method to be used in mint and burn operations.
    /// @dev Uses transient storage to keep track of unique token balances.
    function _computeTotalPoolValue(address baseToken) private returns (uint256 poolValue) {
        // make sure we can later convert token values in base token. Asserted before anything else to prevent potential holder burn failure.
        require(IEOracle(address(this)).hasPriceFeed(baseToken), BaseTokenPriceFeedError());
        AddressSet storage values = activeTokensSet();

        ApplicationsSlot storage appsBitmap = activeApplications();
        uint256 packedApps = appsBitmap.packedApplications;

        // try and get positions balances. Will revert if not successul and prevent incorrect nav calculation.
        try IEApps(address(this)).getAppTokenBalances(_getActiveApplications()) returns (ExternalApp[] memory apps) {
            // position balances can be negative, positive, or null (handled explicitly later)
            for (uint256 i = 0; i < apps.length; i++) {
                // active positions tokens are a subset of active tokens
                for (uint256 j = 0; j < apps[i].balances.length; j++) {
                    // push application if not active but tokens are returned from it (as with GRG staking and univ3 liquidity)
                    if (!ApplicationsLib.isActiveApplication(packedApps, uint256(apps[i].appType))) {
                        activeApplications().storeApplication(apps[i].appType);
                    }

                    // Always add or update the balance from positions
                    if (apps[i].balances[j].amount != 0) {
                        // cache balances in temporary storage
                        int256 storedBalance = apps[i].balances[j].token.getBalance();

                        // verify token in active tokens set, add it otherwise (relevant for pool deployed before v4)
                        if (storedBalance == 0) {
                            // will add to set only if not already stored
                            values.addUnique(IEOracle(address(this)), apps[i].balances[j].token, baseToken);
                        }

                        storedBalance += int256(apps[i].balances[j].amount);
                        // store balance and make sure slot is not cleared to prevent trying to add token again
                        apps[i].balances[j].token.storeBalance(storedBalance != 0 ? storedBalance : int256(1));
                    }
                }
            }
        } catch Error(string memory reason) {
            // we prevent returning pool value when any of the tracked applications fails, as they are not expected to
            revert(reason);
        }

        // initialize pool value as base token balances (wallet balance plus apps balances)
        int256 poolValueInBaseToken = _getAndClearBalance(baseToken);

        // active tokens include any potentially not stored app token, like when a pool upgrades from v3 to v4
        address[] memory activeTokens = activeTokensSet().addresses;
        int256[] memory tokenAmounts = new int256[](activeTokens.length);

        // base token is not stored in activeTokens array
        for (uint256 i = 0; i < activeTokens.length; i++) {
            tokenAmounts[i] = _getAndClearBalance(activeTokens[i]);
        }

        if (activeTokens.length > 0) {
            poolValueInBaseToken += IEOracle(address(this))
                .convertBatchTokenAmounts(activeTokens, tokenAmounts, baseToken);
        }

        // we never return 0, so updating stored value won't clear storage, i.e. an empty slot means a non-minted pool
        return (uint256(poolValueInBaseToken) > 0 ? uint256(poolValueInBaseToken) : 1);
    }

    /// @dev Returns 0 balance if ERC20 call fails.
    function _getAndClearBalance(address token) private returns (int256 balance) {
        balance = token.getBalance();

        // clear temporary storage if used
        if (balance != 0) {
            token.storeBalance(0);
        }

        // the active tokens list contains unique addresses
        if (token == _ZERO_ADDRESS) {
            balance += int256(address(this).balance - msg.value);
        } else {
            try IERC20(token).balanceOf(address(this)) returns (uint256 _balance) {
                balance += int256(_balance);
            } catch {
                // returns 0 balance if the ERC20 balance cannot be found
                return 0;
            }
        }
    }

    /// virtual methods
    function _getActiveApplications() internal view virtual returns (uint256);
}
