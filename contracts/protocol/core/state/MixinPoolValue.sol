// SPDX-License-Identifier: Apache 2.0
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

// TODO: check make catastrophic failure resistant, i.e. must always be possible to liquidate pool + must always
//  use base token balances. If cannot guarantee base token balances can be retrieved, pointless and can be implemented in extension.
//  General idea is if the component is simple and not requires revisit of logic, implement as library, otherwise
//  implement as extension.
contract MixinPoolValue {
    error BaseTokenBalanceError();

    struct PortfolioComponents {
        address[] activeTokens;
        address[] activeApplications;
        address baseToken;
    }

    struct TokenBalance {
        // written to avoid overwriting balance when the same token is returned multiple times
        bool isStored;
        int256 balance;
    }

    struct TokenBalances {
        mapping(address => TokenBalance) balances;
        uint256 tokensCount;
    }

    function _updateNav() internal override returns (uint256 unitaryValue) {
        unitaryValue = _getUnitaryValue(_getPoolValue());
        // unitary value cannot be nil
        assert(unitaryValue > 0);
        poolTokens().unitaryValue = unitaryValue;
        emit NewNav(msg.sender, address(this), unitaryValue);
    }

    /// @dev Assumes the stored list contain unique elements
    function _getPoolValue() internal /*override*/ returns (uint256 poolValue) {
        // this is called just once, so gas overhead of self calling is acceptable
        PortfolioComponents memory components = IRigoblockV3Pool(address(this)).getPortfolioComponents();
        TokenBalances tokenBalances;

        // TODO: base token could be ETH, must correctly handle
        // also TODO: ETH is not being stored in token list, and we have to check whether a zero address mapping works
        // retrieve base token balance, most likely not nil.
        try IERC20(components.baseToken).balanceOf(address(this)) returns (uint256 _balance) {
            if (_balance > 1) {
                tokenBalances.balances[components.activeTokens[i]].balance = int256(balance);
                tokenBalances.balances[components.activeTokens[i]].isStored = true;
                tokenBalances.tokensCount++;
            }
        } catch {
            // a critical base token balance retrieval error will prevent mint/burn ops
            revert BaseTokenBalanceError();
        }


        // base token is not stored in activeTokens slot, as already stored in baseToken slot
        for (uint256 i = 0; i < components.activeTokens.length; i++) {
            // this condition should always be true, but a double counting would result in wrong mint/burn values
            if (!tokenBalances.balances[components.activeTokens[i]].isStored) {
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
                    tokenBalances.balances[components.activeTokens[i]].balance = int256(balance);
                    tokenBalances.balances[components.activeTokens[i]].isStored = true;
                    tokenBalances.tokensCount++;
                }
            }
        }

        if (components.activeApplications.length > 0) {
            for (i = 0; i < components.activeApplications.length; i++) {
                // do not stop aum calculation in case of application adapter failure
                // only 1 adapter for all external applications, to prevent selector clashing. If want to use
                // multiple adapters, will have to route to the correct extension from the general extension,
                // or we should call the application's adapter directly (though less desirable to call directly)
                try IAExternalApplication(address(this)).getUnderlyingTokens(
                    components.activeApplications[i]
                ) returns (address[] memory tokens, int256[] memory amounts) {
                    
                    // position balances can be negative or positive, an edge case is if nil positions are not
                    // pruned, which is explicitly handled later
                    for (uint j = 0; j < tokens.length; j++) {
                        tokenBalances.balances[tokens[j]].balance += amounts[j];

                        // increase tokens count only the first time a balance is stored in memory
                        if (!tokenBalances.balances[tokens[j]].isStored) {
                            tokenBalances.balances[tokens[j]].isStored = true;
                            tokenBalances.tokensCount++;
                        }
                    }
                } catch {
                    continue;
                }
            }
        }

        int256 poolValueInBaseToken;

        for (uint i = 0; i < tokenBalances.tokensCount; i++) {
            tokensValue += _getBaseTokenValue(
                tokenBalances[balances.tokens[i]],
                tokenBalances[balances.tokens[i]],
                components.baseToken,
            );
        }

        // we never return 0, so updating stored value won't clear storage, i.e. an empty slot means a non-minted pool
        return (poolValueInBaseToken > 0 ? uint256(poolValueInBaseToken) : 1);
    }

    /// @dev TODO: add Assumes baseToken is never stored in the token list, i.e. never same as token
    function _getBaseTokenValue(address memory token, uint256 memory amount, address baseToken)
        private
        returns (uint256 value)
    {
        // a pool that has only base token balances will always return correct nav even in case of oracle failure
        // token can be base token, and a position might return a nil balance
        if (token == baseToken || amount == 0) {
            return amount;
        }

        // perform a staticcall to oracle extension
        try IEOracle(address(this)).getBaseTokenValue(token, amount, baseToken) returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
    }
}