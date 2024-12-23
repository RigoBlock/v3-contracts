// SPDX-License-Identifier: Apache-2.0
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

import {PositionValue} from "@uniswap/v3-periphery/contracts/libraries/PositionValue.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import "../IGrgProxy.sol";
import "../IUniv3Pm.sol";
import "../IUniv4Pm.sol";

pragma solidity 0.8.28;

/// @notice A universal aggregator for external contracts positions.
/// @dev External positions are consolidating into a single view contract. As more apps are connected, can be split into multiple mixing.
/// @dev Future-proof as can route to dedicated extensions, should the size of the contract become too big. 
contract EApps {
    using ApplicationsLib for uint256;
    using StateLibrary for IPoolManager;

    error UnknownApplication(Application appType);

    IGrgProxy private immutable _grgStakingProxy;
    IUniv3Pm private immutable _uniV3NPM;
    IUniv4Pm private immutable _uniV4Posm;

    bytes32 private immutable _uniV4PosmPositionsSlot;

    // persistent storage slots, used to read from proxy storage without having to update implementation
    bytes32 private constant _UNIV4_TOKEN_IDS_SLOT = bytes32(uint256(keccak256("Eapps.uniV4.tokenIds")) - 1);

    constructor(address grgStakingProxy, address univ3pm, address univ4pm) {
        _grgStakingProxy = IGrgProxy(grgStakingProxy);
        _uniV3NPM = IUniv3Pm(univ3pm);
        _uniV4Posm = IUniv4Pm(univ4pm);
    }

    /// @notice Supported Applications.
    /// @dev Preserve order when adding new applications, last one is the counter.
    enum Applications {
        GRG_STAKING,
        UNIV3_LIQUIDITY,
        UNIV4_LIQUIDITY,
        // append new applications here, up to a total of 31
        COUNT
    }

    struct UniV4Position {
        // TODO: verify we need this
        mapping(address => uint256 poolId) poolIdsByAddress;
        uint256[] poolIds;
    }

    struct AppTokenBalance {
        address token;
        int128 amount;
    }

    struct App {
        AppTokenBalance[] balances;
        uint256 appType; // converted to uint to facilitate supporting new apps
    }

    function getAppTokenBalances(uint256 packedApplications) external view returns (App[] memory) {
        uint256 activeAppCount;

        // Count how many applications are active
        for (uint256 i = 0; i < uint256(Applications.COUNT); i++) {
            if (packedApplications.isActiveApplication(i)) {
                activeAppCount++;
            }
        }

        App[] memory nestedBalances = new App[][](activeAppCount);
        uint256 activeAppIndex = 0;

        for (uint256 i = 0; i < uint256(Applications.COUNT); i++) {
            if (packedApplications.isActiveApplication(i)) {
                nestedBalances[activeAppIndex++] = (_handleApplication(Applications(i), address(this)), Applications(i));
            } else {
                // grg staking and univ3 liquidity are pre-existing applications that do not require an upgrade, so they won't be
                // stored. However, future upgrades may change that and we use this fallback block until implemented. 
                if (Applications(i) == Applications.GRG_STAKING || Applications(i) == Applications.UNIV3_LIQUIDITY) {
                    nestedBalances[activeAppIndex++] = (_handleApplication(Applications(i), address(this)), Applications(i));
                }
            }
        }

        return nestedBalances;
    }

    /// @notice Directly retrieve balances from target application contract.
    /// @dev A failure to get response from one application will revert the entire call.
    /// @dev This is ok as we do not want to produce an inaccurate nav.
    function _handleApplication(Applications appType) private view returns (AppTokenBalance[] memory balances) {
        if (appType == Applications.GRG_STAKING) {
            balances = _getGrgStakingProxyBalances();
        } else if (appType == Applications.UNIV3_LIQUIDITY) {
            balances = _getUniV3PmBalances();
        } else if (appType == Applications.UNIV4_LIQUIDITY) {
            balances = _getUniV4PmBalances();
        } else {
            revert UnknownApplication(appType);
        }
    }

    function _getGrgStakingProxyBalances() private view returns (AppTokenBalance[] memory balances) {
        balances = new AppTokenBalance[](1);
        balances[0].token = _grgStakingProxy().getGrgContract();
        balances[0].amount = int128(_grgStakingProxy().getTotalStake(address(this)));
        balances[0].amount += int128(_grgStakingProxy().computeRewardBalanceOfDelegator(bytes32(address(this)), address(this)));
    }

    /// @dev Using the oracle protects against manipulations of position tokens via slot0 (i.e. via flash loans)
    function _getUniV3PmBalances() private view returns (AppTokenBalance[] memory) {
        uint256 numPositions = _uniV3NPM.balanceOf(address(this));

        // only get first 20 positions as no pool has more than that and we can save gas plus prevent DOS
        uint256 maxLength = numPositions < 20 ? numPositions * 2 : 40;
        AppTokenBalance[] memory balances = new AppTokenBalance[](maxLength);

        // TODO: we should check if we could cache prices in tstore, but this is an extension, and whether we want to
        // return the cachedPrices against eth, as we are going to need them again to covert these values in MixinPoolValue
        // cache prices.
        uint160[] memory cachedPrices = new uint160[](0);

        for (uint i = 0; i < maxLength / 2; i++) {
            uint256 tokenId = _uniV3NPM.tokenOfOwnerByIndex(address(this), i);
            (,, address token0, address token1,,,,,,,,) = _uniV3NPM.positions(tokenId);

            // Compute balance index once
            uint256 currentBalanceIndex = i * 2;

            // minimize oracle calls by caching value for pair and its reciprocal
            uint160 sqrtPriceX96 = _findCachedPrice(balances, cachedPrices, currentBalanceIndex, token0, token1);
            if (sqrtPriceX96 == 0) {
                // If not cached, fetch from oracle and cache it
                sqrtPriceX96 = IEOracle(address(this)).getCrossSqrtPriceX96(token0, token1);
                cachedPrices = appendCachedPrice(cachedPrices, sqrtPriceX96);
            }

            (uint256 amount0, uint256 amount1) = PositionValue.total(_uniV3NPM, tokenId, sqrtPriceX96);

            balances[currentBalanceIndex] = AppTokenBalance(token0, int128(amount0));
            balances[currentBalanceIndex + 1] = AppTokenBalance(token: token1, amount: int128(amount1));
        }
        // non-aggregated balances are returned
        return balances;
    }

    // Helper function to find if a price for a token pair is cached
    function _findCachedPrice(AppTokenBalance[] memory balances, uint160[] memory prices, uint256 index, address token0, address token1) private pure returns (uint160) {
        if (index != 0) {
            for (uint i = 0; i < prices.length; i++) {
                if (balances[index - 2].token == token0 && balances[index - 1].token == token1) {
                    return prices[i];
                }
            }
        }
        return 0;
    }

    // Helper function to append a new cached price
    function appendCachedPrice(uint160[] memory prices, uint160 price) private pure returns (uint160[] memory) {
        uint160[] memory newPrices = new uint160[](prices.length + 1);
        for (uint i = 0; i < prices.length; i++) {
            newPrices[i] = prices[i];
        }
        newPrices[prices.length] = price;
        return newPrices;
    }

    struct TokenIdsSlot {
        uint256 tokenIds;
    }

    // TODO: we reuse this one in uniswap adapter, should import from library
    function _uniV4TokenIdsSlot() internal pure returns (TokenIdsSlot storage s) {
        assembly {
            s.slot := _UNIV4_TOKEN_IDS_SLOT
        }
    }

    /// @dev Assumes a hook does not influence liquidity.
    /// @dev Value of fees can be inflated by pool operator https://github.com/Uniswap/v4-core/blob/a22414e4d7c0d0b0765827fe0a6c20dfd7f96291/src/libraries/StateLibrary.sol#L153
    function _getUniV4PmBalances() private view returns (AppTokenBalance[] memory) {
        uint256 numPositions = _uniV4Posm.balanceOf(address(this));

        // TODO: remove check when storage asserts limit cannot be broken
        // only get first 255 positions. In production, no more than 255 liquidity positions can be created.
        uint256 maxLength = numPositions < 255 ? numPositions * 2 : 255;
        AppTokenBalance[] memory balances = new AppTokenBalance[](maxLength);
        uint160[] memory cachedPrices = new uint160[](0);

        // need to store the owned tokensIds array or mapping
        // access stored position ids
        // TODO: check use EnumerableSet but overwritten with our specs
        uint256[] memory tokenIds = _uniV4TokenIdsSlot().tokenIds;

        // TODO: verify if should return only first n positions in case more are stored (but they shouldn't)
        for (uint i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            (PoolKey memory poolKey, PositionInfo info) = _uniV4Posm.getPoolAndPositionInfo(tokenId);
            (int24 tickLower, int24 tickUpper) = (info.tickLower(), info.tickUpper());
            address token0 = Currency.unwrap(poolKey.currency0);
            address token1 = Currency.unwrap(poolKey.currency1);

            uint256 currentBalanceIndex = i * 2;

            (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = 
                _uniV4Posm.positionManager().getPositionInfo(
                    poolKey.toId(),
                    address(this),
                    tickLower,
                    tickUpper,
                    bytes32(tokenId)
                );

            uint160 sqrtPriceX96 = _findCachedPrice(balances, cachedPrices, currentBalanceIndex, token0, token1);

            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                liquidity
            );

            // notice: `getFeeGrowthInside` uses `getFeeGrowthGlobals`, which can be inflated by donating to the position
            // https://github.com/Uniswap/v4-core/blob/a22414e4d7c0d0b0765827fe0a6c20dfd7f96291/src/libraries/StateLibrary.sol#L153
            (uint256 poolFeeGrowthInside0X128, uint256 poolFeeGrowthInside1X128) =
                _uniV4Posm.positionManager().getFeeGrowthInside(poolKey.toId(), tickLower, tickUpper);
            amount0 += FullMath.mulDiv(poolFeeGrowthInside0X128 - feeGrowthInside0LastX128, liquidity, FixedPoint128.Q128);
            amount1 += FullMath.mulDiv(poolFeeGrowthInside1X128 - feeGrowthInside1LastX128, liquidity, FixedPoint128.Q128);

            balances[currentBalanceIndex] = AppTokenBalance(token0, int128(amount0));
            balances[currentBalanceIndex + 1] = AppTokenBalance(token: token1, amount: int128(amount1));
        }
        return balances;
    }
}
