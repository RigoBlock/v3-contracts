// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

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
import {VirtualStorageLib} from "../libraries/VirtualStorageLib.sol";
import {Applications} from "../types/Applications.sol";
import {AppTokenBalance} from "../types/ExternalApp.sol";
import {IStaking} from "../../staking/interfaces/IStaking.sol";
import {IStorage} from "../../staking/interfaces/IStorage.sol";
import {GmxLib} from "./GmxLib.sol";
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

    /// @notice Flag to identify out-of-range positions in Uniswap V4
    int24 internal constant OUT_OF_RANGE_FLAG = -887273;

    address internal constant ZERO_ADDRESS = address(0);

    struct NavData {
        uint256 totalValue; // Total pool value in base token
        uint256 unitaryValue; // NAV per share
        uint256 timestamp; // Block timestamp when calculated
    }

    function getAppTokenBalances(
        address pool,
        address grgStakingProxy,
        address uniV4Posm
    ) internal view returns (AppTokenBalance[] memory balances) {
        uint256 packedApps = ISmartPoolState(pool).getActiveApplications();
        uint256 appsCount = uint256(Applications.COUNT);
        AppTokenBalance[][] memory appBalances = new AppTokenBalance[][](appsCount);
        uint256 activeAppIndex;
        uint256 tokenIndex;

        // Populate appBalances array with balances from each ACTIVE application only
        for (uint256 i = 0; i < appsCount; i++) {
            if (!ApplicationsLib.isActiveApplication(packedApps, i)) continue;

            if (Applications(i) == Applications.GRG_STAKING) {
                appBalances[activeAppIndex] = _getGrgStakingProxyBalances(pool, grgStakingProxy);
            } else if (Applications(i) == Applications.UNIV4_LIQUIDITY) {
                appBalances[activeAppIndex] = _getUniV4PmBalances(pool, uniV4Posm);
            } else if (Applications(i) == Applications.GMX_V2_POSITIONS) {
                appBalances[activeAppIndex] = GmxLib.getGmxPositionBalances(pool);
            } else {
                continue;
            }

            tokenIndex += appBalances[activeAppIndex++].length;
        }

        // Flatten all app balances into a single array
        AppTokenBalance[] memory flattenedBalances = new AppTokenBalance[](tokenIndex);
        tokenIndex = 0;

        for (uint256 i = 0; i < appBalances.length; i++) {
            for (uint256 j = 0; j < appBalances[i].length; j++) {
                flattenedBalances[tokenIndex++] = appBalances[i][j];
            }
        }

        // we write a new array with total length but unique tokens
        AppTokenBalance[] memory uniqueBalances = new AppTokenBalance[](tokenIndex);

        uint256 uniqueTokensCount;

        // Aggregate balances by token
        for (uint256 i = 0; i < tokenIndex; i++) {
            bool found;

            for (uint256 j = 0; j < uniqueTokensCount; j++) {
                if (uniqueBalances[j].token == flattenedBalances[i].token) {
                    uniqueBalances[j].amount += flattenedBalances[i].amount;
                    found = true;
                    break;
                }
            }

            if (!found) {
                uniqueBalances[uniqueTokensCount++] = flattenedBalances[i];
            }
        }

        // Resize array to actual unique token count
        assembly {
            mstore(uniqueBalances, uniqueTokensCount)
        }

        return uniqueBalances;
    }

    function getNavData(
        address pool,
        address grgStakingProxy,
        address uniV4Posm
    ) internal view returns (NavData memory) {
        // Get token balances
        AppTokenBalance[] memory balances = _getTokensAndBalances(pool, grgStakingProxy, uniV4Posm);

        // Get pool data
        address baseToken = StorageLib.pool().baseToken;
        uint8 decimals = StorageLib.pool().decimals;

        // Calculate total value
        int256 totalValue = 0;

        // Count non-base tokens for batch conversion
        uint256 nonBaseTokenCount = 0;
        for (uint256 i = 0; i < balances.length; i++) {
            if (balances[i].token == baseToken) {
                totalValue += balances[i].amount;
            } else if (balances[i].amount != 0) {
                nonBaseTokenCount++;
            }
        }

        if (nonBaseTokenCount > 0) {
            address[] memory tokens = new address[](nonBaseTokenCount);
            int256[] memory amounts = new int256[](nonBaseTokenCount);
            uint256 idx = 0;

            for (uint256 i = 0; i < balances.length; i++) {
                if (balances[i].token != baseToken && balances[i].token != ZERO_ADDRESS && balances[i].amount != 0) {
                    tokens[idx] = balances[i].token;
                    amounts[idx] = balances[i].amount;
                    idx++;
                }
            }

            // Convert all non-base tokens to base token value
            try IEOracle(pool).convertBatchTokenAmounts(tokens, amounts, baseToken) returns (int256 convertedValue) {
                totalValue += convertedValue;
            } catch {
                // If conversion fails, early return zero
                return NavData({totalValue: 0, unitaryValue: 0, timestamp: 0});
            }
        }

        // Get total supply (actual + virtual) using signed arithmetic
        ISmartPoolState.PoolTokens memory poolTokens = ISmartPoolState(pool).getPoolTokens();
        int256 virtualSupply = VirtualStorageLib.getVirtualSupply();
        int256 effectiveSupply = int256(poolTokens.totalSupply) + virtualSupply;

        // Calculate unitary value
        uint256 unitaryValue;
        if (effectiveSupply <= 0) {
            // Use stored value or initial value of 1.0 (par value)
            unitaryValue = poolTokens.unitaryValue > 0 ? poolTokens.unitaryValue : 10 ** decimals;
        } else if (totalValue > 0) {
            unitaryValue = (uint256(totalValue) * 10 ** decimals) / uint256(effectiveSupply);
        } else {
            // Supply exists but value is 0 or negative (worthless or underwater)
            // Return 0 to prevent new mints until value recovers
            unitaryValue = 0;
        }

        return
            NavData({
                totalValue: totalValue > 0 ? uint256(totalValue) : 0,
                unitaryValue: unitaryValue,
                timestamp: block.timestamp
            });
    }

    function _getTokensAndBalances(
        address pool,
        address grgStakingProxy,
        address uniV4Posm
    ) private view returns (AppTokenBalance[] memory) {
        // Get active tokens and application balances
        ISmartPoolState.ActiveTokens memory tokens = ISmartPoolState(pool).getActiveTokens();
        AppTokenBalance[] memory appBalances = getAppTokenBalances(pool, grgStakingProxy, uniV4Posm);

        // define new array of max length (active tokens + base token + app tokens)
        uint256 portfolioTokensLength = tokens.activeTokens.length + 1;
        uint256 maxLength = portfolioTokensLength + appBalances.length;
        AppTokenBalance[] memory aggregatedBalances = new AppTokenBalance[](maxLength);
        uint256 index;

        // store the app balances
        for (uint256 i = 0; i < appBalances.length; i++) {
            aggregatedBalances[i] = appBalances[i];
        }

        // update position to store next token balances
        index = appBalances.length;
        address token;

        for (uint256 k = 0; k < portfolioTokensLength; k++) {
            if (k == portfolioTokensLength - 1) {
                token = tokens.baseToken;
            } else if (portfolioTokensLength > 1) {
                token = tokens.activeTokens[k];
            }

            int256 bal;
            if (token == ZERO_ADDRESS) {
                bal = int256(pool.balance);
            } else {
                bal = int256(IERC20(token).balanceOf(pool));
            }

            aggregatedBalances[index++] = AppTokenBalance({token: token, amount: bal});
        }

        return aggregatedBalances;
    }

    function _getGrgStakingProxyBalances(
        address pool,
        address grgStakingProxy
    ) private view returns (AppTokenBalance[] memory balances) {
        uint256 stakingBalance = IStaking(grgStakingProxy).getTotalStake(pool);

        // Continue querying unclaimed rewards only with positive balance
        if (stakingBalance > 0) {
            balances = new AppTokenBalance[](1);
            balances[0].token = address(IStaking(grgStakingProxy).getGrgContract());
            bytes32 poolId = IStorage(grgStakingProxy).poolIdByRbPoolAccount(pool);
            balances[0].amount += (stakingBalance +
                IStaking(grgStakingProxy).computeRewardBalanceOfDelegator(poolId, pool)).toInt256();
        }
    }

    function _getUniV4PmBalances(
        address pool,
        address uniV4Posm
    ) private view returns (AppTokenBalance[] memory balances) {
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
                _findCrossPrice(pool, Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1)),
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

    // -------------------------------------------------------------------------
    // GMX v2 position valuation (view-only mirror of EApps._getGmxV2PositionBalances)
    // -------------------------------------------------------------------------
    function _findCrossPrice(address pool, address token0, address token1) private view returns (uint160 sqrtPriceX96) {
        int24 twap0;
        int24 twap1;

        if (!IEOracle(pool).hasPriceFeed(token0)) {
            twap0 = OUT_OF_RANGE_FLAG;
        } else {
            twap0 = IEOracle(pool).getTwap(token0);
        }

        if (!IEOracle(pool).hasPriceFeed(token1)) {
            twap1 = OUT_OF_RANGE_FLAG;
        } else {
            twap1 = IEOracle(pool).getTwap(token1);
        }

        if (twap0 == OUT_OF_RANGE_FLAG || twap1 == OUT_OF_RANGE_FLAG) {
            return 0;
        }

        return TickMath.getSqrtPriceAtTick(twap1 - twap0);
    }
}
