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

import {TransientSlot} from "@openzeppelin/contracts/contracts/utils/TransientSlot.sol";

// TODO: check make catastrophic failure resistant, i.e. must always be possible to liquidate pool + must always
//  use base token balances. If cannot guarantee base token balances can be retrieved, pointless and can be implemented in extension.
//  General idea is if the component is simple and not requires revisit of logic, implement as library, otherwise
//  implement as extension.
contract MixinPoolValue {
    using TransientSlot for Int256Slot;

    error BaseTokenBalanceError();

    // TODO: verify move to immutables
    bytes32 private constant _TRANSIENT_BALANCE_SLOT = bytes32(uint256(keccak256("mixin.value.transient.balance")) - 1);

    struct PortfolioTokens {
        address[] activeTokens;
        address baseToken;
    }

    struct TokenBalance {
        // flag to avoid overwriting balance should the same token be returned multiple times
        bool isStored;
        int256 balance;
    }

    function _updateNav() internal override returns (uint256 unitaryValue) {
        unitaryValue = _getUnitaryValue(_getPoolValue());

        // unitary value cannot be null
        assert(unitaryValue > 0);
        poolTokens().unitaryValue = unitaryValue;
        emit NewNav(msg.sender, address(this), unitaryValue);
    }

    /// @dev Assumes the stored list contain unique elements
    function _getPoolValue() internal /*override*/ returns (uint256 poolValue) {
        // this is called just once, so gas overhead of self calling is acceptable
        // TODO: as this is calling self, not an extension, we could simply call the method directly
        // check where we define in the inheritance architecture so can inherit state and read directly
        //PortfolioTokens memory components = IRigoblockV3Pool(address(this)).getPortfolioTokens();
        PortfolioTokens memory components = getPortfolioTokens();

        // base token is not stored in activeTokens slot, as already stored in baseToken slot
        // TODO: token must be stored in the active tokens at mint or burn liquidity, removed at burn or sell or add liquidity
        for (uint256 i = 0; i < components.activeTokens.length; i++) {
            // TODO: verify how base token is taken into account, as we could store it when minting and it will be there until pruning
            // the active tokens list contains unique addresses
            uint256 balance;
            if (components.activeTokens[i] == address(0)) {
                balance = address(this).balance;
            } else {
                try IERC20(components.activeTokens[i]).balanceOf(address(this)) returns (uint256 _balance) {
                    balance = _balance;
                } catch {
                    // do not stop aum calculation in case of chain's base currency or rogue token
                    continue;
                }
            }

            if (balance > 1) {
                _storeBalance(components.activeTokens[i], int256(balance));
            }
        }

        // TODO: move to types
        struct AppTokenBalance {
            address token;
            int128 amount;
        }

        struct App {
            AppTokenBalance[] balances;
            uint256 appType; // converted to uint to facilitate supporting new apps
        }

        // try and get positions balances. Will revert if not successul and prevent incorrect nav calculation.
        try IEApps(address(this)).getAppTokenBalances(applications().packedApplications) returns (App[] memory apps) {
            // position balances can be negative, positive, or null (handled explicitly later)
            for (i = 0; i < apps.length; i++) {
                // active positions tokens are a subset of active tokens
                for (uint j = 0; j < apps[i].balances.length; j++) {
                    // Always add or update the balance from positions
                    if (apps[i].balances[j].amount != 0) {
                        int256 newBalance = _getBalance(apps[i].balances[j].token) + int256(apps[i].balances[j].amount);
                        _storeBalance(apps[i].balances[j].token, newBalance);
                    }
                }
            }
        } catch Error(string memory reason) {
            // we prevent returning pool value when one of the tracked applications fails
            revert reason;
        }

        int256 poolValueInBaseToken;

        for (uint256 i = 0; i < components.activeTokens.length; i++) {
            int256 balance = _getBalance(components.activeTokens[i]);

            // clear transient storage slot as we do not need them any more
            _storeBalance(components.activeTokens[i], 0);

            if (balance < 0) {
                poolValueInBaseToken -= int256(_getBaseTokenValue(
                    components.activeTokens[i],
                    uint256(-balance),
                    components.baseToken,
                ));
            } else {
                poolValueInBaseToken += int256(_getBaseTokenValue(
                    components.activeTokens[i],
                    uint256(balance),
                    components.baseToken
                ));
            }
        }

        // we never return 0, so updating stored value won't clear storage, i.e. an empty slot means a non-minted pool
        return (poolValueInBaseToken > 0 ? uint256(poolValueInBaseToken) : 1);
    }

    /// @dev Base token is always passed once in the loop
    function _getBaseTokenValue(address token, uint256 amount, address baseToken)
        private
        returns (uint256 value)
    {
        // early return for base token or if amount nil, like when a sum of positions leads to nil amount
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
        _TRANSIENT_BALANCE_SLOT.tstore(key, token);
    }

    function _getBalance(address token) private view returns (int256) {
        bytes32 key = _TRANSIENT_BALANCE_SLOT.deriveMapping(token);
        return _TRANSIENT_BALANCE_SLOT.tload(key);
    }
}