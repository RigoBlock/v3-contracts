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

import {FixedPoint128} from "@uniswap/v3-core/contracts/libraries/FixedPoint128.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {NativeWrapper} from "@uniswap/v4-periphery/src/base/NativeWrapper.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {IEApps} from "./adapters/interfaces/IEApps.sol";
import {Applications} from "../types/Applications.sol";
import {AppTokenBalance, ExternalApp} from "../types/ExternalApp.sol";
import {IEOracle} from "../../protocol/extensions/adapters/interfaces/IEOracle.sol";
import {ApplicationsLib} from "../../protocol/libraries/ApplicationsLib.sol";
import {IStaking} from "../../staking/interfaces/IStaking.sol";
import {IStorage} from "../../staking/interfaces/IStorage.sol";

/// @notice A universal aggregator for external contracts positions.
/// @dev External positions are consolidating into a single view contract. As more apps are connected, can be split into multiple mixing.
/// @dev Future-proof as can route to dedicated extensions, should the size of the contract become too big.
contract EApps is IEApps {
    using ApplicationsLib for uint256;
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

    error UnknownApplication(uint256 appType);

    IStaking private immutable _grgStakingProxy;
    INonfungiblePositionManager private immutable _uniV3NPM;
    IPositionManager private immutable _uniV4Posm;

    // persistent storage slots, used to read from proxy storage without having to update implementation
    // bytes32(uint256(keccak256("Eapps.uniV4.tokenIds")) - 1)
    bytes32 private constant _UNIV4_TOKEN_IDS_SLOT = 0x27616b43efe6cac399303df84ec58b87084277217488937eeb864ace11507167;

    /// @notice The different immutable addresses will result in different deployed addresses on different networks.
    constructor(address grgStakingProxy, address univ3Npm, address univ4Posm) {
        _grgStakingProxy = IStaking(grgStakingProxy);
        _uniV3NPM = INonfungiblePositionManager(univ3Npm);
        _uniV4Posm = IPositionManager(univ4Posm);
    }

    struct Application {
        bool isActive;
    }

    // TODO: maybe we could use a fixed-size bytes1[31]?
    function getAppTokenBalances(uint256 packedApplications) external view override returns (ExternalApp[] memory) {
        uint256 activeAppCount;
        Application[] memory apps = new Application[](uint256(Applications.COUNT));

        // Count how many applications are active
        for (uint256 i = 0; i < uint256(Applications.COUNT); i++) {
            if (packedApplications.isActiveApplication(uint256(Applications(i)))) {
                activeAppCount++;
                apps[i].isActive = true;
            // grg staking and univ3 liquidity are pre-existing applications that do not require an upgrade, so they are not
            // stored. However, future upgrades may change that and we use this fallback block until implemented.
            } else if (Applications(i) == Applications.GRG_STAKING || Applications(i) == Applications.UNIV3_LIQUIDITY) {
                activeAppCount++;
                apps[i].isActive = true;
            } else {
                continue;
            }
        }

        ExternalApp[] memory nestedBalances = new ExternalApp[](activeAppCount);
        uint256 activeAppIndex = 0;

        for (uint256 i = 0; i < uint256(Applications.COUNT); i++) {
            if (apps[i].isActive) {
                nestedBalances[activeAppIndex].balances = _handleApplication(Applications(i));
                nestedBalances[activeAppIndex].appType = uint256(Applications(i));
                activeAppIndex++;
            }
        }
        return nestedBalances;
    }

    // TODO: uncomment applications after implementing univ4Posm in test pipeline
    /// @notice Directly retrieve balances from target application contract.
    /// @dev A failure to get response from one application will revert the entire call.
    /// @dev This is ok as we do not want to produce an inaccurate nav.
    function _handleApplication(Applications appType) private view returns (AppTokenBalance[] memory balances) {
        if (appType == Applications.GRG_STAKING) {
            balances = _getGrgStakingProxyBalances();
        } else if (appType == Applications.UNIV3_LIQUIDITY) {
            balances = _getUniV3PmBalances();
        //} else if (appType == Applications.UNIV4_LIQUIDITY) {
        //    balances = _getUniV4PmBalances();
        //} else {
        //    revert UnknownApplication(uint256(appType));
        }
    }

    function _getGrgStakingProxyBalances() private view returns (AppTokenBalance[] memory balances) {
        balances = new AppTokenBalance[](1);
        balances[0].token = address(_grgStakingProxy.getGrgContract());
        balances[0].amount = int256(_grgStakingProxy.getTotalStake(address(this)));
        bytes32 poolId = IStorage(address(_grgStakingProxy)).poolIdByRbPoolAccount(address(this));
        balances[0].amount += int256(_grgStakingProxy.computeRewardBalanceOfDelegator(poolId, address(this)));
    }

    /// @dev Using the oracle protects against manipulations of position tokens via slot0 (i.e. via flash loans)
    function _getUniV3PmBalances() private view returns (AppTokenBalance[] memory) {
        uint256 numPositions = _uniV3NPM.balanceOf(address(this));

        // only get first 20 positions as no pool has more than that and we can save gas plus prevent DOS
        uint256 maxLength = numPositions < 20 ? numPositions * 2 : 40;

        CacheParams memory params;
        params.balances = new AppTokenBalance[](maxLength);

        // TODO: we should check if we could cache prices in tstore, but this is an extension, and whether we want to
        // return the cachedPrices against eth, as we are going to need them again to covert these values in MixinPoolValue
        // cache prices.
        params.prices = new uint160[](0);

        for (uint256 i = 0; i < maxLength / 2; i++) {
            uint256 tokenId = _uniV3NPM.tokenOfOwnerByIndex(address(this), i);
            (
                ,
                ,
                address token0,
                address token1,
                ,
                int24 tickLower,
                int24 tickUpper,
                uint128 liquidity,
                ,
                ,
                ,

            ) = _uniV3NPM.positions(tokenId);
            params.token0 = token0;
            params.token1 = token1;

            // Compute balance index once
            params.index = i * 2;

            // minimize oracle calls by caching value for pair and its reciprocal
            uint160 sqrtPriceX96 = _findCachedPrice(params);
            if (sqrtPriceX96 == 0) {
                // If not cached, fetch from oracle and cache it
                sqrtPriceX96 = IEOracle(address(this)).getCrossSqrtPriceX96(params.token0, params.token1);
                params.prices = _appendCachedPrice(params.prices, sqrtPriceX96);
            }

            // we resort to v4 tests library, as PositionValue.sol and FullMath in v3 LiquidityAmounts require solc <0.8
            // for simplicity, as uni v3 liquidity is remove-only, we exclude unclaimed fees, which incentivizes migrating liquidity to v4.
            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                liquidity
            );

            params.balances[params.index].token = params.token0;
            params.balances[params.index].amount = int256(amount0);
            params.balances[params.index + 1].token = params.token1;
            params.balances[params.index + 1].amount = int256(amount1);
        }
        // non-aggregated balances are returned
        return params.balances;
    }

    struct CacheParams {
        AppTokenBalance[] balances;
        uint160[] prices;
        uint256 index;
        address token0;
        address token1;
    }

    // Helper function to find if a price for a token pair is cached
    function _findCachedPrice(CacheParams memory params) private pure returns (uint160) {
        if (params.index != 0) {
            for (uint256 i = 0; i < params.prices.length; i++) {
                if (
                    params.balances[params.index - 2].token == params.token0 &&
                    params.balances[params.index - 1].token == params.token1
                ) {
                    return params.prices[i];
                }
            }
        }
        return 0;
    }

    // Helper function to append a new cached price
    function _appendCachedPrice(uint160[] memory prices, uint160 price) private pure returns (uint160[] memory) {
        // TODO: define length in memory to say storage reads
        uint160[] memory newPrices = new uint160[](prices.length + 1);
        for (uint256 i = 0; i < prices.length; i++) {
            newPrices[i] = prices[i];
        }
        // TODO: modified to use newPrices.length, verify if prev using prices.length was a bug
        newPrices[newPrices.length] = price;
        return newPrices;
    }

    struct TokenIdsSlot {
        uint256[] tokenIds;
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
        // access stored position ids
        uint256[] memory tokenIds = _uniV4TokenIdsSlot().tokenIds;

        CacheParams memory params;
        params.balances = new AppTokenBalance[](tokenIds.length);
        params.prices = new uint160[](0);

        // a maximum of 255 positons can be created, so this loop will not break memory or block limits
        for (uint256 i = 0; i < tokenIds.length; i++) {
            (PoolKey memory poolKey, PositionInfo info) = _uniV4Posm.getPoolAndPositionInfo(tokenIds[i]);
            (int24 tickLower, int24 tickUpper) = (info.tickLower(), info.tickUpper());
            params.token0 = Currency.unwrap(poolKey.currency0);
            params.token1 = Currency.unwrap(poolKey.currency1);

            params.index = i * 2;

            (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = _uniV4Posm
                .poolManager()
                .getPositionInfo(poolKey.toId(), address(this), tickLower, tickUpper, bytes32(tokenIds[i]));

            uint160 sqrtPriceX96 = _findCachedPrice(params);
            if (sqrtPriceX96 == 0) {
                // If not cached, fetch from oracle and cache it
                sqrtPriceX96 = IEOracle(address(this)).getCrossSqrtPriceX96(params.token0, params.token1);
                params.prices = _appendCachedPrice(params.prices, sqrtPriceX96);
            }

            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                liquidity
            );

            // notice: `getFeeGrowthInside` uses `getFeeGrowthGlobals`, which can be inflated by donating to the position
            // https://github.com/Uniswap/v4-core/blob/a22414e4d7c0d0b0765827fe0a6c20dfd7f96291/src/libraries/StateLibrary.sol#L153
            (uint256 poolFeeGrowthInside0X128, uint256 poolFeeGrowthInside1X128) = _uniV4Posm
                .poolManager()
                .getFeeGrowthInside(poolKey.toId(), tickLower, tickUpper);
            amount0 += FullMath.mulDiv(
                poolFeeGrowthInside0X128 - feeGrowthInside0LastX128,
                liquidity,
                FixedPoint128.Q128
            );
            amount1 += FullMath.mulDiv(
                poolFeeGrowthInside1X128 - feeGrowthInside1LastX128,
                liquidity,
                FixedPoint128.Q128
            );

            params.balances[params.index].token = params.token0;
            params.balances[params.index].amount = int256(amount0);
            params.balances[params.index + 1].token = params.token1;
            params.balances[params.index + 1].amount = int256(amount1);
        }
        return params.balances;
    }
}
