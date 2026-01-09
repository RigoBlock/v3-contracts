// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin-legacy/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IEOracle} from "../extensions/adapters/interfaces/IEOracle.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {ISmartPoolState} from "../interfaces/v4/pool/ISmartPoolState.sol";
import {AddressSet, EnumerableSet} from "../libraries/EnumerableSet.sol";
import {ApplicationsLib} from "../libraries/ApplicationsLib.sol";
import {SlotDerivation} from "../libraries/SlotDerivation.sol";
import {StorageLib} from "../libraries/StorageLib.sol";
import {VirtualBalanceLib} from "../libraries/VirtualBalanceLib.sol";
import {Applications} from "../types/Applications.sol";
import {AppTokenBalance, ExternalApp} from "../types/ExternalApp.sol";
import {IStaking} from "../../staking/interfaces/IStaking.sol";
import {IStorage} from "../../staking/interfaces/IStorage.sol";
/// @title NavView - Internal library for navigation and application view functionality
/// @notice Provides internal functions to calculate NAV and retrieve application balances
/// @dev This library contains the core logic for the ENavView extension
/// @author Gabriele Rigo - <gab@rigoblock.com>
library NavView {
    using ApplicationsLib for uint256;
    using EnumerableSet for AddressSet;
    using SlotDerivation for bytes32;
    using SafeCast for uint256;
    using SafeCast for int256;
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

    /// @notice Error thrown for unknown application types
    error UnknownApplication(uint256 appType);

    /// @notice Flag to identify out-of-range positions in Uniswap V4
    int24 internal constant OUT_OF_RANGE_FLAG = -887273;

    /// @notice Zero address constant
    address internal constant ZERO_ADDRESS = address(0);

    /// @notice Represents a token balance including virtual balances and application positions
    struct TokenBalance {
        address token;
        int256 balance; // Signed to support virtual balances and app positions
    }

    /// @notice Complete NAV data for a pool
    struct NavData {
        uint256 totalValue; // Total pool value in base token
        uint256 unitaryValue; // NAV per share
        uint256 timestamp; // Block timestamp when calculated
    }

    /// @notice Gets application token balances for external positions
    /// @param grgStakingProxy Address of the GRG staking proxy
    /// @param uniV4Posm Address of the Uniswap V4 position manager
    /// @return apps Array of ExternalApp structs with balances
    function getAppTokenBalances(
        address grgStakingProxy,
        address uniV4Posm
    ) internal view returns (ExternalApp[] memory apps) {
        uint256 packedApplications = StorageLib.activeApplications().packedApplications;
        uint256 activeAppCount;
        bool[] memory appStates = new bool[](uint256(Applications.COUNT));

        // Count active applications
        for (uint256 i = 0; i < uint256(Applications.COUNT); i++) {
            if (packedApplications.isActiveApplication(uint256(Applications(i)))) {
                activeAppCount++;
                appStates[i] = true;
            } else if (Applications(i) == Applications.GRG_STAKING) {
                // GRG staking is always checked as a pre-existing application
                activeAppCount++;
                appStates[i] = true;
            }
        }

        apps = new ExternalApp[](activeAppCount);
        uint256 activeAppIndex = 0;

        for (uint256 i = 0; i < uint256(Applications.COUNT); i++) {
            if (appStates[i]) {
                apps[activeAppIndex].balances = handleApplication(Applications(i), grgStakingProxy, uniV4Posm);
                apps[activeAppIndex].appType = uint256(Applications(i));
                activeAppIndex++;
            }
        }
    }

    /// @notice Returns all token balances including virtual balances and application positions
    /// @param grgStakingProxy Address of the GRG staking proxy
    /// @param uniV4Posm Address of the Uniswap V4 position manager
    /// @return balances Array of TokenBalance structs
    function getTokensAndBalances(
        address grgStakingProxy,
        address uniV4Posm
    ) internal view returns (TokenBalance[] memory balances) {
        // Get active tokens
        ISmartPoolState.ActiveTokens memory tokens = ISmartPoolState(address(this)).getActiveTokens();

        // Create memory arrays to track unique tokens and their balances
        address[] memory uniqueTokens = new address[](tokens.activeTokens.length + 100); // Buffer for app tokens
        int256[] memory tokenBalances = new int256[](tokens.activeTokens.length + 100);
        uint256 tokenCount = 0;

        // Get application balances
        ExternalApp[] memory apps = getAppTokenBalances(grgStakingProxy, uniV4Posm);

        // Process application balances
        for (uint256 i = 0; i < apps.length; i++) {
            for (uint256 j = 0; j < apps[i].balances.length; j++) {
                if (apps[i].balances[j].amount != 0) {
                    address token = apps[i].balances[j].token;
                    int256 amount = apps[i].balances[j].amount;

                    // Find if token already tracked
                    bool tokenFound = false;
                    for (uint256 k = 0; k < tokenCount; k++) {
                        if (uniqueTokens[k] == token) {
                            tokenBalances[k] += amount;
                            tokenFound = true;
                            break;
                        }
                    }

                    if (!tokenFound) {
                        uniqueTokens[tokenCount] = token;
                        tokenBalances[tokenCount] = amount;
                        tokenCount++;
                    }
                }
            }
        }

        // Add base token balance: only add native balance if base token is native (address(0))
        int256 baseTokenBalance = 0;
        if (tokens.baseToken == ZERO_ADDRESS) {
            // For native token, add native balance
            baseTokenBalance = int256(address(this).balance);
        }
        // Always add virtual balance for base token
        baseTokenBalance += VirtualBalanceLib.getVirtualBalance(tokens.baseToken);

        bool baseTokenFound = false;
        for (uint256 k = 0; k < tokenCount; k++) {
            if (
                uniqueTokens[k] == tokens.baseToken ||
                (tokens.baseToken == ZERO_ADDRESS && uniqueTokens[k] == ZERO_ADDRESS)
            ) {
                tokenBalances[k] += baseTokenBalance;
                baseTokenFound = true;
                break;
            }
        }

        if (!baseTokenFound) {
            uniqueTokens[tokenCount] = tokens.baseToken;
            tokenBalances[tokenCount] = baseTokenBalance;
            tokenCount++;
        }

        // Add active tokens wallet balances + virtual balances
        for (uint256 i = 0; i < tokens.activeTokens.length; i++) {
            address token = tokens.activeTokens[i];
            int256 totalBalance = 0;

            // Get wallet balance
            try IERC20(token).balanceOf(address(this)) returns (uint256 _balance) {
                totalBalance = int256(_balance);
            } catch {
                // Continue even if balance read fails, might have virtual balance
            }

            // Add virtual balance for this token
            totalBalance += VirtualBalanceLib.getVirtualBalance(token);

            // Skip if no balance (wallet + virtual)
            if (totalBalance == 0) continue;

            // Find if token already tracked
            bool walletTokenFound = false;
            for (uint256 k = 0; k < tokenCount; k++) {
                if (uniqueTokens[k] == token) {
                    tokenBalances[k] += totalBalance;
                    walletTokenFound = true;
                    break;
                }
            }

            if (!walletTokenFound) {
                uniqueTokens[tokenCount] = token;
                tokenBalances[tokenCount] = totalBalance;
                tokenCount++;
            }
        }

        // Create result array with actual count
        balances = new TokenBalance[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            balances[i] = TokenBalance({token: uniqueTokens[i], balance: tokenBalances[i]});
        }
    }

    /// @notice Returns complete NAV data for the pool
    /// @param grgStakingProxy Address of the GRG staking proxy
    /// @param uniV4Posm Address of the Uniswap V4 position manager
    /// @return navData Struct containing totalValue, unitaryValue, and timestamp
    function getNavData(address grgStakingProxy, address uniV4Posm) internal view returns (NavData memory navData) {
        // Get token balances
        TokenBalance[] memory balances = getTokensAndBalances(grgStakingProxy, uniV4Posm);

        // Get pool data
        address baseToken = StorageLib.pool().baseToken;
        uint8 decimals = StorageLib.pool().decimals;

        // Calculate total value
        int256 totalValue = 0;

        // Count non-base tokens for batch conversion
        uint256 nonBaseTokenCount = 0;
        for (uint256 i = 0; i < balances.length; i++) {
            if (balances[i].token == baseToken || balances[i].token == ZERO_ADDRESS) {
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
                if (balances[i].token != baseToken && balances[i].token != ZERO_ADDRESS && balances[i].balance != 0) {
                    tokens[idx] = balances[i].token;
                    amounts[idx] = balances[i].balance;
                    idx++;
                }
            }

            // Convert all non-base tokens to base token value
            try IEOracle(address(this)).convertBatchTokenAmounts(tokens, amounts, baseToken) returns (
                int256 convertedValue
            ) {
                totalValue += convertedValue;
            } catch {
                // If conversion fails, return zero
                return NavData({totalValue: 0, unitaryValue: 0, timestamp: block.timestamp});
            }
        }

        // Get total supply (actual + virtual)
        ISmartPoolState.PoolTokens memory poolTokens = ISmartPoolState(address(this)).getPoolTokens();
        uint256 totalSupply = poolTokens.totalSupply;

        // Add virtual supply for cross-chain transfers (matches MixinPoolValue)
        totalSupply += VirtualBalanceLib.getVirtualSupply().toUint256();

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

    /// @notice Handles balance retrieval for a specific application type
    /// @param appType The application type to handle
    /// @param grgStakingProxy Address of the GRG staking proxy
    /// @param uniV4Posm Address of the Uniswap V4 position manager
    /// @return balances Array of AppTokenBalance structs
    function handleApplication(
        Applications appType,
        address grgStakingProxy,
        address uniV4Posm
    ) internal view returns (AppTokenBalance[] memory balances) {
        if (appType == Applications.GRG_STAKING) {
            balances = getGrgStakingProxyBalances(grgStakingProxy);
        } else if (appType == Applications.UNIV4_LIQUIDITY) {
            balances = getUniV4PmBalances(uniV4Posm);
        } else {
            revert UnknownApplication(uint256(appType));
        }
    }

    /// @notice Gets GRG staking proxy balances
    /// @param grgStakingProxy Address of the GRG staking proxy
    /// @return balances Array of AppTokenBalance structs
    /// @dev Will return an empty array in case no stake found but unclaimed rewards exist
    function getGrgStakingProxyBalances(
        address grgStakingProxy
    ) internal view returns (AppTokenBalance[] memory balances) {
        uint256 stakingBalance = IStaking(grgStakingProxy).getTotalStake(address(this));

        // Continue querying unclaimed rewards only with positive balance
        if (stakingBalance > 0) {
            balances = new AppTokenBalance[](1);
            balances[0].token = address(IStaking(grgStakingProxy).getGrgContract());
            bytes32 poolId = IStorage(grgStakingProxy).poolIdByRbPoolAccount(address(this));
            balances[0].amount += (stakingBalance +
                IStaking(grgStakingProxy).computeRewardBalanceOfDelegator(poolId, address(this))).toInt256();
        }
    }

    /// @notice Gets Uniswap V4 position manager balances
    /// @param uniV4Posm Address of the Uniswap V4 position manager
    /// @return balances Array of AppTokenBalance structs
    /// @dev Assumes hooks do not influence liquidity and uses oracle to protect against manipulation
    function getUniV4PmBalances(address uniV4Posm) internal view returns (AppTokenBalance[] memory balances) {
        // Access stored position IDs
        uint256[] memory tokenIds = StorageLib.uniV4TokenIdsSlot().tokenIds;
        uint256 length = tokenIds.length;
        balances = new AppTokenBalance[](length * 2);

        // Maximum of 255 positions can be created, so this loop won't break memory or block limits
        for (uint256 i = 0; i < length; i++) {
            (PoolKey memory poolKey, PositionInfo info) = IPositionManager(uniV4Posm).getPoolAndPositionInfo(
                tokenIds[i]
            );

            // Accept evaluation error by excluding unclaimed fees, which can be inflated arbitrarily
            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                findCrossPrice(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1)),
                TickMath.getSqrtPriceAtTick(info.tickLower()),
                TickMath.getSqrtPriceAtTick(info.tickUpper()),
                IPositionManager(uniV4Posm).getPositionLiquidity(tokenIds[i])
            );

            balances[i * 2].token = Currency.unwrap(poolKey.currency0);
            balances[i * 2].amount = amount0.toInt256();
            balances[i * 2 + 1].token = Currency.unwrap(poolKey.currency1);
            balances[i * 2 + 1].amount = amount1.toInt256();
        }
    }

    /// @notice Finds cross price between two tokens using oracle TWAPs
    /// @param token0 First token address
    /// @param token1 Second token address
    /// @return sqrtPriceX96 The square root price in X96 format, or 0 if no price feeds available
    function findCrossPrice(address token0, address token1) internal view returns (uint160 sqrtPriceX96) {
        int24 twap0;
        int24 twap1;

        if (!IEOracle(address(this)).hasPriceFeed(token0)) {
            twap0 = OUT_OF_RANGE_FLAG;
        } else {
            twap0 = IEOracle(address(this)).getTwap(token0);
        }

        if (!IEOracle(address(this)).hasPriceFeed(token1)) {
            twap1 = OUT_OF_RANGE_FLAG;
        } else {
            twap1 = IEOracle(address(this)).getTwap(token1);
        }

        if (twap0 == OUT_OF_RANGE_FLAG || twap1 == OUT_OF_RANGE_FLAG) {
            return 0;
        }

        return TickMath.getSqrtPriceAtTick(twap1 - twap0);
    }
}
