// SPDX-License-Identifier: Apache-2.0-or-later
/*

 Copyright 2024 Rigo Intl.

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

import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {MixinOwnerActions} from "../actions/MixinOwnerActions.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {IEApps} from "../../extensions/adapters/interfaces/IEApps.sol";
import {IEOracle} from "../../extensions/adapters/interfaces/IEOracle.sol";
import {AppTokenBalance, ExternalApp} from "../../types/ExternalApp.sol";

// TODO: check make catastrophic failure resistant, i.e. must always be possible to liquidate pool + must always
//  use base token balances. If cannot guarantee base token balances can be retrieved, pointless and can be implemented in extension.
//  General idea is if the component is simple and not requires revisit of logic, implement as library, otherwise
//  implement as extension.
// TODO: MixinPoolState should inherit from MixinPoolValue as needs to display some data. Meaning some methods will have to be inverted
abstract contract MixinPoolValue is MixinOwnerActions {
    type Int256Slot is bytes32;
    using TransientSlot for *;
    using SlotDerivation for bytes32;

    error BaseTokenBalanceError();

    // TODO: verify correctness
    bytes32 private constant _TRANSIENT_BALANCE_SLOT = bytes32(uint256(keccak256("mixin.value.transient.balance")) - 1);

    function _updateNav() internal override returns (uint256 unitaryValue) {
        unitaryValue = _getUnitaryValue();

        // unitary value cannot be null
        assert(unitaryValue > 0);
        poolTokens().unitaryValue = unitaryValue;
        emit NewNav(msg.sender, address(this), unitaryValue);
    }

    /// @notice Updates the stored value with an updated one.
    /// @dev Assumes the stored list contain unique elements.
    /// @dev A write method to be used in mint and burn operations.
    function _getPoolValue() internal returns (uint256 poolValue) {
        int256 newBalance;

        // try and get positions balances. Will revert if not successul and prevent incorrect nav calculation.
        try IEApps(address(this)).getAppTokenBalances(_getActiveApplications()) returns (ExternalApp[] memory apps) {
            // position balances can be negative, positive, or null (handled explicitly later)
            for (uint256 i = 0; i < apps.length; i++) {
                // active positions tokens are a subset of active tokens
                for (uint j = 0; j < apps[i].balances.length; j++) {
                    // Always add or update the balance from positions
                    if (apps[i].balances[j].amount != 0) {
                        newBalance = _getBalance(apps[i].balances[j].token) + int256(apps[i].balances[j].amount);
                        _storeBalance(apps[i].balances[j].token, newBalance);
                    }
                }
            }
        } catch Error(string memory reason) {
            // we prevent returning pool value when any of the tracked applications fails
            revert(reason);
        }

        // TODO: tokens in apps but not active are not accounted for unless they are the base token. This for example when an
        // old extension does not push token to active tokens. We could create a new array with app tokens and any additionally
        // held token.
        ActiveTokens memory tokens = _getActiveTokens();
        uint256 length = tokens.activeTokens.length;
        address targetToken;
        int256 poolValueInBaseToken;

        // wrappedNative is not stored as an immutable to allow deploying at the same address on multiple networks
        address wrappedNative;
        try IEApps(address(this)).wrappedNative() returns (address _wrappedNative) {
            wrappedNative = _wrappedNative;
        } catch {}

        // base token is not stored in activeTokens slot, so we add it as an additional element at the end of the loop
        for (uint256 i = 0; i <= length; i++) {
            targetToken = i == length ? tokens.baseToken : tokens.activeTokens[i];
            newBalance = _getBalance(targetToken);

            // clear temporary storage if used
            if (newBalance != 0) {
                _storeBalance(targetToken, 0);
            }

            // the active tokens list contains unique addresses
            if (targetToken == address(0)) {
                newBalance += int256(address(this).balance);
            } else {
                try IERC20(targetToken).balanceOf(address(this)) returns (uint256 _balance) {
                    newBalance += int256(_balance);
                } catch {
                    // do not stop aum calculation in case of chain's base currency or rogue token
                    continue;
                }
            }

            // TODO: verify use ZERO_ADDRESS
            // convert wrapped native to native to potentially skip one or more conversions
            if (targetToken == wrappedNative) {
                targetToken == address(0);
            }

            // base token is always appended at the end of the loop
            if (tokens.baseToken == wrappedNative) {
                tokens.baseToken == address(0);
            }

            if (newBalance < 0) {
                poolValueInBaseToken -= int256(_getBaseTokenValue(
                    targetToken,
                    uint256(-newBalance),
                    tokens.baseToken
                ));
            } else {
                poolValueInBaseToken += int256(_getBaseTokenValue(
                    targetToken,
                    uint256(newBalance),
                    tokens.baseToken
                ));
            }
        }

        // we never return 0, so updating stored value won't clear storage, i.e. an empty slot means a non-minted pool
        return (poolValueInBaseToken > 0 ? uint256(poolValueInBaseToken) : 1);
    }

    // TODO: assert not possible to inflate total supply to manipulate pool price.
    /// @notice Uses transient storage to keep track of unique token balances.
    function _getUnitaryValue() internal returns (uint256) {
        uint256 poolSupply = poolTokens().totalSupply;
        uint256 storedValue = poolTokens().unitaryValue;
        uint256 poolValue = _getPoolValue();

        // a previously minted pool cannot have storedValue = 0 
        if (storedValue != 0) {
            // default scenario
            if (poolValue != 0 && poolSupply != 0) {
                return poolValue / poolSupply;
            // fallback to stored value when value would be null or infinite
            } else {
                return storedValue;
            }
        // return 1 in base token units at first mint
        } else {
            return 10 ** pool().decimals;
        }
    }

    function _getBaseTokenValue(address token, uint256 amount, address baseToken)
        private
        view
        returns (uint256)
    {
        if (token == baseToken || amount == 0) {
            return amount;
        }

        // perform a staticcall to oracle extension
        try IEOracle(address(this)).convertTokenAmount(token, amount, baseToken) returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
    }

    // Helper functions for tstore operations
    /// @notice Stores a mapping of token addresses to int256 balances
    function _storeBalance(address token, int256 balance) private {
        bytes32 key = _TRANSIENT_BALANCE_SLOT.deriveMapping(token);
        key.asInt256().tstore(balance);
    }

    function _getBalance(address token) private view returns (int256) {
        bytes32 key = _TRANSIENT_BALANCE_SLOT.deriveMapping(token);
        return key.asInt256().tload();
    }

    /// virtual methods
    function _getActiveApplications() internal view virtual returns (uint256);
    function _getActiveTokens() internal view virtual returns (ActiveTokens memory);
}