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

import {SafeCast} from "@openzeppelin-legacy/contracts/utils/math/SafeCast.sol";
import {OffchainApps} from "./OffchainApps.sol";
import {IEApps} from "../extensions/adapters/interfaces/IEApps.sol";
import {IEOracle} from "../extensions/adapters/interfaces/IEOracle.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {ISmartPoolState} from "../interfaces/v4/pool/ISmartPoolState.sol";
import {AddressSet, EnumerableSet} from "../libraries/EnumerableSet.sol";
import {ApplicationsLib, ApplicationsSlot} from "../libraries/ApplicationsLib.sol";
import {SlotDerivation} from "../libraries/SlotDerivation.sol";
import {StorageLib} from "../libraries/StorageLib.sol";
import {ExternalApp} from "../types/ExternalApp.sol";

// TODO: once this has been completed as "view", if we implemented as an extension, this contract could be updated in the new implementation
// otherwise, the address of this contract must be updated every time we upgrade the implementation. Also from a i.e. defillama's perspective, it might be less auditable.
/// @title OffchainNav - Offchain NAV calculation for Rigoblock smart pools.
/// @notice Provides view methods to retrieve token balances and NAV without transient storage.
/// @dev Designed for off-chain queries like DeFiLlama, subgraphs, or ZK proof generation.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract OffchainNav is OffchainApps {
    using ApplicationsLib for ApplicationsSlot;
    using EnumerableSet for AddressSet;
    using SlotDerivation for bytes32;
    using SafeCast for uint256;

    // TODO: import these storage slots from other contracts
    bytes32 private constant _POOL_INIT_SLOT = 0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8;
    bytes32 private constant _TOKEN_REGISTRY_SLOT = 0x3dcde6752c7421366e48f002bbf8d6493462e0e43af349bebb99f0470a12300d;
    bytes32 private constant _VIRTUAL_BALANCES_SLOT = 0x19797d8be84f650fe18ebccb97578c2adb7abe9b7c86852694a3ceb69073d1d1;
    bytes32 private constant _APPLICATIONS_SLOT = 0xdc487a67cca3fd0341a90d1b8834103014d2a61e6a212e57883f8680b8f9c831;
    address private constant _ZERO_ADDRESS = address(0);

    constructor(address grgStakingProxy, address univ4Posm) OffchainApps(grgStakingProxy, univ4Posm) {}

    struct TokenBalance {
        address token;
        int256 balance; // Signed to support virtual balances and app positions
    }

    struct NavData {
        uint256 totalValue;    // Total pool value in base token
        uint256 unitaryValue;  // NAV per share
        uint256 timestamp;     // Block timestamp when calculated
    }

    /// @notice Returns all token balances including virtual balances and application positions
    /// @param pool Address of the Rigoblock pool
    /// @return balances Array of TokenBalance structs
    /// @dev This is not a view function because getAppTokenBalances uses transient storage.
    ///      Can still be called off-chain via eth_call for read-only queries.
    // TODO: we cannot declare as `view` because it calls IEApps(pool).getAppTokenBalances(packedApps)
    function getTokensAndBalances(address pool) public view returns (TokenBalance[] memory balances) {
        // Get active tokens and active applications
        ISmartPoolState.ActiveTokens memory tokens = ISmartPoolState(pool).getActiveTokens();
        uint256 packedApps = ISmartPoolState(pool).getActiveApplications();
        
        // TODO: this is not right
        // Create memory arrays to track unique tokens and their balances
        address[] memory uniqueTokens = new address[](tokens.activeTokens.length + 100); // Buffer for app tokens
        int256[] memory tokenBalances = new int256[](tokens.activeTokens.length + 100);
        uint256 tokenCount = 0;
        
        // Try to get application balances
        // TODO: no lazy implementation - should re-implement here without modifying storage, i.e. we will be able to make the method view
        ExternalApp[] memory apps = _getOffchainAppTokenBalances(packedApps, pool);

        for (uint256 i = 0; i < apps.length; i++) {
            for (uint256 j = 0; j < apps[i].balances.length; j++) {
                if (apps[i].balances[j].amount != 0) {
                    address token = apps[i].balances[j].token;
                    int256 amount = apps[i].balances[j].amount;
                    
                    // Find if token already tracked
                    bool found = false;
                    for (uint256 k = 0; k < tokenCount; k++) {
                        if (uniqueTokens[k] == token) {
                            tokenBalances[k] += amount;
                            found = true;
                            break;
                        }
                    }
                    
                    if (!found) {
                        uniqueTokens[tokenCount] = token;
                        tokenBalances[tokenCount] = amount;
                        tokenCount++;
                    }
                }
            }
        }

        {
            // TODO: why pool.balance? the baseToken can be any token
            int256 baseBalance = int256(pool.balance) + _getVirtualBalance(tokens.baseToken);
            bool found = false;
            for (uint256 k = 0; k < tokenCount; k++) {
                // TODO: wrong, base token is never in the active tokens array, and is returned by tokens.baseToken
                if (uniqueTokens[k] == tokens.baseToken || uniqueTokens[k] == _ZERO_ADDRESS) {
                    tokenBalances[k] += baseBalance;
                    found = true;
                    break;
                }
            }
            if (!found) {
                // TODO: not sure this is the correct way of adding, as later we will lose the ability to append to the same token?
                uniqueTokens[tokenCount] = tokens.baseToken;
                tokenBalances[tokenCount] = baseBalance;
                tokenCount++;
            }
        }
        
        // Add active tokens wallet balances
        for (uint256 i = 0; i < tokens.activeTokens.length; i++) {
            address token = tokens.activeTokens[i];
            int256 walletBalance = 0;
            
            try IERC20(token).balanceOf(pool) returns (uint256 _balance) {
                walletBalance = int256(_balance);
            } catch {
                // Skip if balance read fails
                continue;
            }
            
            // Find if token already tracked
            bool found = false;
            for (uint256 k = 0; k < tokenCount; k++) {
                if (uniqueTokens[k] == token) {
                    tokenBalances[k] += walletBalance;
                    found = true;
                    break;
                }
            }
            
            if (!found) {
                uniqueTokens[tokenCount] = token;
                tokenBalances[tokenCount] = walletBalance;
                tokenCount++;
            }
        }
        
        // Create result array with actual count
        balances = new TokenBalance[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            balances[i] = TokenBalance({
                token: uniqueTokens[i],
                balance: tokenBalances[i]
            });
        }
    }

    /// @notice Returns complete NAV data for a pool
    /// @param pool Address of the Rigoblock pool
    /// @return navData Struct containing totalValue, unitaryValue, and timestamp
    function getNavData(address pool) external view returns (NavData memory navData) {
        // Get token balances
        TokenBalance[] memory balances = getTokensAndBalances(pool);
        
        // Get base token
        address baseToken = StorageLib.pool().baseToken;
        uint8 decimals = StorageLib.pool().decimals;
        
        // Initialize with base token value (already in base token)
        int256 totalValue = 0;
        
        // Prepare arrays for batch conversion (excluding base token)
        uint256 nonBaseTokenCount = 0;
        for (uint256 i = 0; i < balances.length; i++) {
            // TODO: this does not look right
            if (balances[i].token == baseToken || balances[i].token == _ZERO_ADDRESS) {
                totalValue += balances[i].balance;
            } else if (balances[i].balance != 0) {
                nonBaseTokenCount++;
            }
        }
        
        if (nonBaseTokenCount > 0) {
            address[] memory tokens = new address[](nonBaseTokenCount);
            int256[] memory amounts = new int256[](nonBaseTokenCount);
            uint256 idx = 0;
            
            for (uint256 i = 0; i < balances.length; i++) {
                if (balances[i].token != baseToken && balances[i].token != _ZERO_ADDRESS && balances[i].balance != 0) {
                    tokens[idx] = balances[i].token;
                    amounts[idx] = balances[i].balance;
                    idx++;
                }
            }
            
            // Convert all non-base tokens to base token value
            try IEOracle(pool).convertBatchTokenAmounts(tokens, amounts, baseToken) returns (int256 convertedValue) {
                totalValue += convertedValue;
            } catch {
                // If conversion fails, return zero
                return NavData({
                    totalValue: 0,
                    unitaryValue: 0,
                    timestamp: block.timestamp
                });
            }
        }
        
        // Get total supply
        ISmartPoolState.PoolTokens memory poolTokens = ISmartPoolState(pool).getPoolTokens();
        uint256 totalSupply = poolTokens.totalSupply;
        
        // Calculate unitary value
        uint256 unitaryValue;
        if (totalSupply == 0) {
            // Use stored value or initial value
            unitaryValue = poolTokens.unitaryValue > 0 ? poolTokens.unitaryValue : 10 ** decimals;
        } else if (totalValue > 0) {
            unitaryValue = (uint256(totalValue) * 10 ** decimals) / totalSupply;
        } else {
            unitaryValue = 10 ** decimals; // Minimum value
        }
        
        navData = NavData({
            totalValue: totalValue > 0 ? uint256(totalValue) : 0,
            unitaryValue: unitaryValue,
            timestamp: block.timestamp
        });
    }

    /// @dev Gets the virtual balance for a token from storage.
    function _getVirtualBalance(address token) private view returns (int256 value) {
        bytes32 slot = _VIRTUAL_BALANCES_SLOT.deriveMapping(token);
        assembly {
            value := sload(slot)
        }
    }
}
