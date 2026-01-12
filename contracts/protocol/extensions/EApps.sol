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
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IERC721Enumerable as IERC721} from "forge-std/interfaces/IERC721.sol";
import {IEOracle} from "../../protocol/extensions/adapters/interfaces/IEOracle.sol";
import {ApplicationsLib} from "../../protocol/libraries/ApplicationsLib.sol";
import {StorageLib} from "../../protocol/libraries/StorageLib.sol";
import {TransientStorage} from "../../protocol/libraries/TransientStorage.sol";
import {IStaking} from "../../staking/interfaces/IStaking.sol";
import {IStorage} from "../../staking/interfaces/IStorage.sol";
import {Applications, TokenIdsSlot} from "../types/Applications.sol";
import {AppTokenBalance, ExternalApp} from "../types/ExternalApp.sol";
import {IEApps} from "./adapters/interfaces/IEApps.sol";

/// @notice A universal aggregator for external contracts positions.
/// @dev External positions are consolidating into a single view contract. As more apps are connected, can be split into multiple mixing.
/// @dev Future-proof as can route to dedicated extensions, should the size of the contract become too big.
contract EApps is IEApps {
    using ApplicationsLib for uint256;
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;
    using TransientStorage for address;
    using SafeCast for uint256;

    error UnknownApplication(uint256 appType);

    int24 private constant OUT_OF_RANGE_FLAG = -887273;

    IStaking private immutable _grgStakingProxy;
    IPositionManager private immutable _uniV4Posm;

    /// @notice The different immutable addresses will result in different deployed addresses on different networks.
    constructor(address grgStakingProxy, address univ4Posm) {
        _grgStakingProxy = IStaking(grgStakingProxy);
        _uniV4Posm = IPositionManager(univ4Posm);
    }

    /// @inheritdoc IEApps
    /// @notice Uses temporary storage to cache token prices, which can be used in MixinPoolValue.
    /// @notice Requires delegatecall.
    function getAppTokenBalances(uint256 packedApplications) external override returns (ExternalApp[] memory) {
        uint256 totalAppsCount = uint256(Applications.COUNT);
        uint256 activeAppCount;
        bool[] memory activeApps = new bool[](totalAppsCount);

        // Count how many applications are active
        for (uint256 i = 0; i < uint256(totalAppsCount); i++) {
            if (packedApplications.isActiveApplication(uint256(Applications(i)))) {
                activeAppCount++;
                activeApps[i] = true;
                // grg staking is a pre-existing application. Therefore, we always check staked balance.
            } else if (Applications(i) == Applications.GRG_STAKING) {
                activeAppCount++;
                activeApps[i] = true;
            } else {
                continue;
            }
        }

        ExternalApp[] memory nestedBalances = new ExternalApp[](activeAppCount);
        uint256 activeAppIndex = 0;

        for (uint256 i = 0; i < uint256(totalAppsCount); i++) {
            if (activeApps[i]) {
                nestedBalances[activeAppIndex].balances = _handleApplication(Applications(i));
                nestedBalances[activeAppIndex].appType = uint256(Applications(i));
                activeAppIndex++;
            }
        }
        return nestedBalances;
    }

    /// @inheritdoc IEApps
    function getUniV4TokenIds() external view override returns (uint256[] memory tokenIds) {
        return StorageLib.uniV4TokenIdsSlot().tokenIds;
    }

    /// @notice Directly retrieve balances from target application contract.
    /// @dev A failure to get response from one application will revert the entire call.
    /// @dev This is ok as we do not want to produce an inaccurate nav.
    function _handleApplication(Applications appType) private returns (AppTokenBalance[] memory balances) {
        if (appType == Applications.GRG_STAKING) {
            balances = _getGrgStakingProxyBalances();
        } else if (appType == Applications.UNIV4_LIQUIDITY) {
            balances = _getUniV4PmBalances();
        } else {
            revert UnknownApplication(uint256(appType));
        }
    }

    /// @dev Will return an empty array in case no stake found but unclaimed rewards (which are earned in the undelegate epoch).
    /// @dev This is fine as the amount is very small and saves several storage reads.
    function _getGrgStakingProxyBalances() private view returns (AppTokenBalance[] memory balances) {
        uint256 stakingBalance = _grgStakingProxy.getTotalStake(address(this));

        // continue querying unclaimed rewards only with positive balance
        if (stakingBalance > 0) {
            balances = new AppTokenBalance[](1);
            balances[0].token = address(_grgStakingProxy.getGrgContract());
            bytes32 poolId = IStorage(address(_grgStakingProxy)).poolIdByRbPoolAccount(address(this));
            balances[0].amount += (stakingBalance +
                _grgStakingProxy.computeRewardBalanceOfDelegator(poolId, address(this))).toInt256();
        }
    }

    /// @dev Assumes a hook does not influence liquidity. This is true as long as it cannot access after remove liquidity deltas.
    /// @dev Using the oracle protects against manipulations of position tokens via slot0 (i.e. via flash loans).
    function _getUniV4PmBalances() private returns (AppTokenBalance[] memory balances) {
        // access stored position ids
        uint256[] memory tokenIds = StorageLib.uniV4TokenIdsSlot().tokenIds;
        uint256 length = tokenIds.length;
        balances = new AppTokenBalance[](length * 2);

        // a maximum of 255 positons can be created, so this loop will not break memory or block limits
        for (uint256 i = 0; i < length; i++) {
            (PoolKey memory poolKey, PositionInfo info) = _uniV4Posm.getPoolAndPositionInfo(tokenIds[i]);

            // we accept an evaluation error by excluding unclaimed fees, which can be inflated arbitrarily
            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                _findCrossPrice(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1)),
                TickMath.getSqrtPriceAtTick(info.tickLower()),
                TickMath.getSqrtPriceAtTick(info.tickUpper()),
                _uniV4Posm.getPositionLiquidity(tokenIds[i])
            );

            balances[i * 2].token = Currency.unwrap(poolKey.currency0);
            balances[i * 2].amount = amount0.toInt256();
            balances[i * 2 + 1].token = Currency.unwrap(poolKey.currency1);
            balances[i * 2 + 1].amount = amount1.toInt256();
        }
    }

    function _findCrossPrice(address token0, address token1) private returns (uint160) {
        int24 twap0 = token0.getTwap();
        int24 twap1 = token1.getTwap();

        if (twap0 == 0) {
            if (!IEOracle(address(this)).hasPriceFeed(token0)) {
                twap0 = OUT_OF_RANGE_FLAG;
            } else {
                twap0 = IEOracle(address(this)).getTwap(token0);
            }

            // update twap for token0 in temporary storage
            token0.storeTwap(twap0);
        }

        if (twap1 == 0) {
            if (!IEOracle(address(this)).hasPriceFeed(token1)) {
                twap1 = OUT_OF_RANGE_FLAG;
            } else {
                twap1 = IEOracle(address(this)).getTwap(token1);
            }

            // update twap for token1 in temporary storage
            token1.storeTwap(twap1);
        }

        if (twap0 == OUT_OF_RANGE_FLAG || twap1 == OUT_OF_RANGE_FLAG) {
            return 0;
        }

        return TickMath.getSqrtPriceAtTick(twap1 - twap0);
    }
}
