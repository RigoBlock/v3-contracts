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
    /// @inheritdoc IEApps
    /// @notice Uses temporary storage to cache token prices, which can be used in MixinPoolValue.
    /// @notice Requires delegatecall.
    function getAppTokenBalances(uint256 packedApplications) external override returns (ExternalApp[] memory) {
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
    function _handleApplication(Applications appType) private returns (AppTokenBalance[] memory balances) {
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
    function _getUniV3PmBalances() private returns (AppTokenBalance[] memory) {
        uint256 numPositions = _uniV3NPM.balanceOf(address(this));

        // only get first 20 positions as no pool has more than that and we can save gas plus prevent DOS
        uint256 maxLength = numPositions < 20 ? numPositions * 2 : 40;
        AppTokenBalance[] memory balances = new AppTokenBalance[](maxLength);

        // flag for storing balances in the right position
        uint256 index;

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

            // minimizes oracle calls by caching value for token0 and token1
            uint160 sqrtPriceX96 = _findCrossPrice(token0, token1);

            index = i * 2;

            // TODO: check if we should try and convert only with a valid price. Also check if we really resort to v4 lib, or if we added to lib/univ3
            // we resort to v4 tests library, as PositionValue.sol and FullMath in v3 LiquidityAmounts require solc <0.8
            // for simplicity, as uni v3 liquidity is remove-only, we exclude unclaimed fees, which incentivizes migrating liquidity to v4.
            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                liquidity
            );

            // TODO: technically, we could convert balances to ETH so we wouldn' need to store many tokens in memory. We should check what works best.
            balances[index].token = token0;
            balances[index].amount = int256(amount0);
            balances[index + 1].token = token1;
            balances[index + 1].amount = int256(amount1);
        }
        // non-aggregated balances are returned
        return balances;
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

    // TODO: modify to use tstore to preserve token price
    /// @dev Assumes a hook does not influence liquidity.
    /// @dev Value of fees can be inflated by pool operator https://github.com/Uniswap/v4-core/blob/a22414e4d7c0d0b0765827fe0a6c20dfd7f96291/src/libraries/StateLibrary.sol#L153
    function _getUniV4PmBalances() private returns (AppTokenBalance[] memory) {
        // access stored position ids
        uint256[] memory tokenIds = _uniV4TokenIdsSlot().tokenIds;
        AppTokenBalance[] memory balances = new AppTokenBalance[](tokenIds.length);

        // flag for storing balances in the right position
        uint256 index;

        // a maximum of 255 positons can be created, so this loop will not break memory or block limits
        for (uint256 i = 0; i < tokenIds.length; i++) {
            (PoolKey memory poolKey, PositionInfo info) = _uniV4Posm.getPoolAndPositionInfo(tokenIds[i]);
            (int24 tickLower, int24 tickUpper) = (info.tickLower(), info.tickUpper());
            address token0 = Currency.unwrap(poolKey.currency0);
            address token1 = Currency.unwrap(poolKey.currency1);

            (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = _uniV4Posm
                .poolManager()
                .getPositionInfo(poolKey.toId(), address(this), tickLower, tickUpper, bytes32(tokenIds[i]));

            uint160 sqrtPriceX96 = _findCrossPrice(token0, token1);

            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                liquidity
            );

            index = i * 2;

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

            balances[index].token = token0;
            balances[index].amount = int256(amount0);
            balances[index + 1].token = token1;
            balances[index + 1].amount = int256(amount1);
        }
        return balances;
    }

    // TODO: can reuse temp mapping as lib?
    function _findCrossPrice(address token0, address token1) private returns (uint160) {
        bytes32 tick0SlotHash = keccak256(abi.encode("temp tick", token0));
        bytes32 tick1SlotHash = keccak256(abi.encode("temp tick", token1));
        // TODO: verify if store as constant
        int24 outOfRangeFlag = -887273;

        int24 tick0;
        int24 tick1;
        uint16 cardinality;

        assembly ("memory-safe") {
            tick0 := tload(tick0SlotHash)
            tick1 := tload(tick1SlotHash)
        }

        if (tick0 == 0) {
            // TODO: we should probably get a TWAP, and/or make some assertions
            (tick0, cardinality) = IEOracle(address(this)).getTick(token0);

            if (cardinality == 0) {
                tick0 = outOfRangeFlag;
            } else if (tick0 == 0) {
                tick0 = 1;
            }
        }

        if (tick1 == 0) {
            (tick1, cardinality) = IEOracle(address(this)).getTick(token1);

            if (cardinality == 0) {
                tick1 = outOfRangeFlag;
            } else if (tick1 == 0) {
                tick1 = 1;
            }
        }

        // store valid ticks
        assembly ("memory-safe") {
            tstore(tick0SlotHash, tick0)
            tstore(tick1SlotHash, tick1)
        }

        if (tick0 == outOfRangeFlag || tick1 == outOfRangeFlag) {
            return 0;
        }

        int24 crossTick = tick0 - tick1;
        return TickMath.getSqrtPriceAtTick(crossTick);
    }
}
