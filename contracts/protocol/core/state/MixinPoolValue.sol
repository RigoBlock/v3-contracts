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
    error InvalidNavUpdate();

    // TODO: we must return address(0) in owned tokens
    struct PortfolioComponents {
        address[] ownedTokens;
        address[] externalApplications;
        address baseToken;
    }

    struct TokenBalance {
        bool isStored;
        int256 balance;
    }

    struct TokenBalances {
        mapping(address => TokenBalance) balances;
        uint256 tokensCount;
    }

    // TODO: verify it is ok to call state internal method, that then calls _getPoolValue in this contract
    function _updateNav() internal override returns (uint256 unitaryValue) {
        unitaryValue = _getUnitaryValue();
        require(unitaryValue > 0, InvalidNavUpdate());
        poolTokens().unitaryValue = unitaryValue;
        emit NewNav(msg.sender, address(this), unitaryValue);
    }

    function _getPoolValue() internal /*override*/ returns (uint256 poolValue) {
        // TODO: verify if base token should be stored in ownedTokens or not, since we already store it in state
        // we could simply return it, and not add to list when swapping.
        // TODO: we could use state instead of calling self to save gas on runtime
        PortfolioComponents memory components = IRigoblockV3Pool(address(this)).getPortfolioComponents();
        TokenBalances tokenBalances;

        for (uint256 i = 0; i < components.ownedTokens.length; i++) {
            try IERC20(components.ownedTokens[i]).balanceOf(address(this)) returns (uint256 balance) {
                // skip nil values (1 could be used to avoid clearing storage)
                if (balance > 1) {
                    tokenBalances.balances[components.ownedTokens[i]].balance = int256(balance);
                    tokenBalances.balances[components.ownedTokens[i]].isStored = true;
                    tokenBalances.tokensCount++;
                }
            } catch {
                // store chain's base currency only once
                if (components.ownedTokens[i] == address(0) && !tokenBalances.balances[components.ownedTokens[i]].isStored) {
                    tokenBalances.balances[components.ownedTokens[i]].balance = address(this).balance;
                    tokenBalances.balances[components.ownedTokens[i]].isStored = true;
                    tokenBalances.tokensCount++;
                }

                // do not stop aum calculation in case of chain's base currency or rogue token
                continue;
            }
        }

        // TODO: when a position returns tokens, we must ensure they are added to stored tokens list,
        // otherwise calculation will be wrong.
        if (components.externalApplications.length > 0) {
            for (i = 0; i < components.externalApplications.length; i++) {
                // do not stop aum calculation in case of application adapter failure
                // only 1 adapter for all external applications, to prevent selector clashing. If want to use
                // multiple adapters, will have to route to the correct extension from the general extension,
                // or we should call the application's adapter directly (though less desirable to call directly)
                try IAExternalApplication(address(this)).getUnderlyingTokens(
                    components.externalApplications[i]
                ) returns (address[] memory tokens, int256[] memory amounts) {
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
                tokenBalances[tokenBalances.tokens[i]],
                tokenBalances[tokenBalances.tokens[i]],
                components.baseToken,
            );
        }

        // we never return 0, so updating stored value won't clear storage
        return (poolValueInBaseToken > 0 ? uint256(poolValueInBaseToken) : 1);
    }

    function _getBaseTokenValue(address memory token, uint256 memory amount, address baseToken)
        private
        returns (uint256 value)
    {
        if (token == baseToken || amount == 0) {
            return amount;
        }

        // TODO: in uniswap, same token can be owned by multiple tokenIds, verify aggregated is returned
        // TODO: check correct decimals conversion in oracle extension
        // value = token * amount * price against base token * decimals adjustment
        // this is the first part we use a moving part, i.e. we can rewrite as library, and implement
        // price return logic in extension. Meaning the call will have to warm up one less contract,
        // and the logic that will need upgrade will be in an extension.
        try IEOracle(address(this)).getBaseTokenValue(token, amount, baseToken) returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
    }
}