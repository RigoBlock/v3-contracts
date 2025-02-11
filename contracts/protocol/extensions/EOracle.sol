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

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IEOracle} from "./adapters/interfaces/IEOracle.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {Observation} from "../types/Observation.sol";

contract EOracle is IEOracle {
    using TickMath for int24;

    address private constant _ZERO_ADDRESS = address(0);

    IOracle private immutable _oracle;

    constructor(address oracleHookAddress) {
        _oracle = IOracle(oracleHookAddress);
    }

    // TODO: check if good idea to use tload to read cached ticks
    /// @inheritdoc IEOracle
    // TODO: as we will use a try statement in the calling method, we could avoid using try/catch statements here to save gas
    // provided we do not need to return important information
    function convertTokenAmount(
        address token,
        uint256 amount,
        address targetToken
    ) external view override returns (uint256 value) {
        PoolKey memory key;
        IOracle.ObservationState memory state;

        // TODO: no need to use try/catch with known oracle contract
        if (token == _ZERO_ADDRESS) {
            (key, state) = _getPool(_ZERO_ADDRESS, targetToken, _getOracle());
            try _getOracle().observe(key, _getSecondsAgos(state.cardinality)) returns (
                int48[] memory tickCumulatives,
                uint144[] memory
            ) {
                uint256 priceX128 = _getPriceX128(tickCumulatives, _getSecondsAgos(state.cardinality));
                value = FullMath.mulDiv(amount, priceX128, 1 << 128); // convert native to token
                return value;
            } catch {
                return value = 0; // Oracle failure or no pair available
            }
        }

        if (targetToken == _ZERO_ADDRESS) {
            // Convert directly to native
            (key, state) = _getPool(_ZERO_ADDRESS, token, _getOracle());

            try _getOracle().observe(key, _getSecondsAgos(state.cardinality)) returns (
                int48[] memory tickCumulatives,
                uint144[] memory
            ) {
                uint256 priceX128 = _getPriceX128(tickCumulatives, _getSecondsAgos(state.cardinality));
                value = FullMath.mulDiv(amount, 1 << 128, priceX128); // convert token to ETH
                return value;
            } catch {
                return value = 0; // Oracle failure or no pair available
            }
        }

        // try and convert token to chain currency
        (key, state) = _getPool(_ZERO_ADDRESS, token, _getOracle());

        try _getOracle().observe(key, _getSecondsAgos(state.cardinality)) returns (
            int48[] memory tickCumulatives,
            uint144[] memory
        ) {
            uint256 priceX128 = _getPriceX128(tickCumulatives, _getSecondsAgos(state.cardinality));
            uint256 ethAmount = FullMath.mulDiv(amount, 1 << 128, priceX128); // convert token to native

            // try and convert chain currency to the target token
            (key, state) = _getPool(_ZERO_ADDRESS, targetToken, _getOracle());

            // TODO: if base token does not have price feed, nav will be 0. Assert that.
            // try to get first conversion
            try _getOracle().observe(key, _getSecondsAgos(state.cardinality)) returns (
                int48[] memory tickCumulativesTarget,
                uint144[] memory
            ) {
                priceX128 = _getPriceX128(tickCumulativesTarget, _getSecondsAgos(state.cardinality));
                value = FullMath.mulDiv(ethAmount, priceX128, 1 << 128); // convert native to base token
                return value;
            } catch {
                return value = 0;
            }
        } catch {
            return value = 0;
        }
    }

    /// @inheritdoc IEOracle
    function getOracleAddress() external view override returns (address) {
        return address(_getOracle());
    }

    /// @dev This method will return true if the last stored observation has a non-nil timestamp.
    /// @dev Adding wrapped native token requires a price feed against navite, as otherwise must warm up EApps in order
    /// to have same contract address on all chains.
    function hasPriceFeed(address token) external view returns (bool) {
        if (token == _ZERO_ADDRESS) {
            return true;
        } else {
            // TODO: if we just verify that the observations[0] exists, we can save 1 storage read for this assertion (need to modify internal getter)
            (PoolKey memory key, IOracle.ObservationState memory state) = _getPool(_ZERO_ADDRESS, token, _getOracle());

            // try and get the last stored observation
            try _getOracle().getObservation(key, state.index) returns (
                Observation memory observation
            ) {
                return observation.blockTimestamp != 0;
            } catch {
                return false;
            }
        }
    }

    /// @notice Returns positive values if token has price feed against chain currency
    function getTick(address token) external view override returns (int24 tick, uint16 cardinality) {
        PoolKey memory key;
        IOracle.ObservationState memory state;

        if (token == _ZERO_ADDRESS) {
            // tick = 0 implies price of 1
            return (0, 1);
        } else {
            (key, state) = _getPool(_ZERO_ADDRESS, token, _getOracle());

            // TODO: should we use a TWAP instead?
            // get last stored observation from oracle
            (Observation memory observation) = _getOracle().getObservation(key, state.index);

            // TODO: a tick could be 0, but this does not mean it is a valid price
            return (observation.prevTick, state.cardinality);
        }
    }

    /// @dev Private method to fetch the oracle address
    function _getOracle() private view returns (IOracle) {
        return _oracle;
    }

    function _getPool(
        address token0,
        address token1,
        IOracle oracle
    ) private view returns (PoolKey memory key, IOracle.ObservationState memory state) {
        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 0,
            tickSpacing: TickMath.MAX_TICK_SPACING,
            hooks: IHooks(address(oracle))
        });
        state = oracle.getState(key);
    }

    function _getPriceX128(
        int48[] memory tickCumulatives,
        uint32[] memory secondsAgos
    ) private pure returns (uint256 priceX128) {
        int56 tickCumulativesDelta = int56(tickCumulatives[1] - tickCumulatives[0]);
        int24 twapTick = int24(tickCumulativesDelta / int56(int32(secondsAgos[0])));
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(int32(secondsAgos[0])) != 0)) twapTick--;

        uint160 sqrtPriceX96 = twapTick.getSqrtPriceAtTick();
        priceX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
    }

    function _getSecondsAgos(uint16 cardinality) private view returns (uint32[] memory) {
        // blocktime cannot be lower than 8 seconds on Ethereum, 1 seconds on any other chain
        uint16 blockTime = block.chainid == 1 ? 8 : 1;
        uint32 maxSecondsAgos = uint32(cardinality * blockTime);
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = maxSecondsAgos > 300 ? 300 : maxSecondsAgos;
        secondsAgos[1] = 0;
        return secondsAgos;
    }
}
