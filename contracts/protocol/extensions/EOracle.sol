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

    IOracle private immutable _oracle;

    constructor(address oracleHookAddress) {
        _oracle = IOracle(oracleHookAddress);
    }

    struct PoolSettings {
        /// @notice The number of stored observations
        uint16 cardinality;
        /// @notice The pool key
        PoolKey memory key;
        /// @notice The time range of the observations
        uint32[] secondsAgos;
    }

    /// @inheritdoc IEOracle
    // TODO: as we will use a try statement in the calling method, we could avoid using try/catch statements here to save gas
    // provided we do not need to return important information
    function convertTokenAmount(address token, uint256 amount, address targetToken)
        external
        view
        override
        returns (uint256 value)
    {
        PoolSettings memory settings;

        if (token == address(0)) {
            settings = _getPoolSettings(address(0), targetToken, address(_getOracle()));
            try _getOracle().observe(settings.key, settings.secondsAgos) returns (int48[] memory tickCumulatives,) {
                uint256 priceX128 = _getPriceX128(tickCumulatives, settings.secondsAgos);
                value = FullMath.mulDiv(amount, priceX128, 1 << 128); // convert native to token
                return value;
            } catch {
                return value = 0; // Oracle failure or no pair available
            }
        }

        if (targetToken == address(0)) {
            // Convert directly to ETH
            settings = _getPoolSettings(address(0), token, address(_getOracle()));

            try _getOracle().observe(settings.key, settings.secondsAgos) returns (int48[] memory tickCumulatives,) {
                uint256 priceX128 = _getPriceX128(tickCumulatives, settings.secondsAgos);
                value = FullMath.mulDiv(amount, 1 << 128, priceX128); // convert token to ETH
                return value;
            } catch {
                return value = 0; // Oracle failure or no pair available
            }
        }

        // try and convert token to chain currency
        settings = _getPoolSettings(address(0), token, address(_getOracle()));

        try _getOracle().observe(settings.key, settings.secondsAgos) returns (int48[] memory tickCumulatives,) {
            uint256 priceX128 = _getPriceX128(tickCumulatives, settings.secondsAgos);
            uint256 ethAmount = FullMath.mulDiv(amount, 1 << 128, priceX128); // convert token to native

            // try and convert chain currency to the target token
            settings = _getPoolSettings(address(0), targetToken, address(_getOracle()));

            // try to get first conversion
            try _getOracle().observe(settings.key, settings.secondsAgos) returns (int48[] memory tickCumulatives,) {
                uint256 priceX128 = _getPriceX128(tickCumulatives, settings.secondsAgos);
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

    /// @dev This method will return true if the last stored observation has a non nil timestamp
    // TODO: verify if instead of the boolean we can return the value directly, or the observation so we can use it for deeper
    // inspections and can skip one check here. Also check if want to check observations[0].timestamp != 0 to save gas
    function hasPriceFeed(address token) external view returns (bool) {
        if (token == address(0)) {
            return true;
        } else {
            PoolSettings memory settings;
            settings = _getPoolSettings(address(0), token, address(_getOracle()));

            try _getOracle().getObservation(settings.key, settings.cardinality)
                view
                returns (Oracle.Observation memory observation)
            {
                return observation.blockTimestamp != 0;
            } catch {
                return false;
            }
        }
    }

    /// @dev Returns the cross rate of a token pair through chain currency rate
    function tryFindCrossRate(token0, token1) external view returns (uint160 sqrtPriceX96) {
        // first try to get rate of token to chain currency
        (uint160 sqrtPriceX96_0) = _tryFindRate(token0);

        // then try to get rate of token to chain currency 
        (uint160 sqrtPriceX96_1) = _tryFindRate(token1);

        // finally return the cross exchange rate from the two rates
        sqrtPriceX96 = _calculateSqrtPriceX96FromSqrtPrices(sqrtPriceX96_0, sqrtPriceX96_1);
    }

    /// @notice Returns positive values if token has price feed against chain currency
    function _tryFindRate(address token) private view returns (uint160 sqrtPriceX96) {
        PoolSettings memory settings;

        if (token == address(0)) {
            return ONE_X96;
        } else {
            settings = _getPoolSettings(address(0), baseToken, address(_getOracle()));

            // get the last stored observation position
            (uint16 index,,) = _getOracle().getState(settings.key);

            try _getOracle().getObservation(settings.key, index) returns (Observation memory observation) {
                sqrtPriceX96 = observation.prevTick.getSqrtPriceAtTick();
            } catch {
                return value = 0; // Oracle failure or no pair available
            }
        }
    }

    function _calculateSqrtPriceX96FromSqrtPrices(uint160 sqrtPriceX96_0, uint160 sqrtPriceX96_1) private pure returns (uint160) {
        if (sqrtPriceX96_1 == 0) return 0; // Division by zero check

        // Scale sqrtPriceX96_0 down to avoid overflow in division
        uint256 scaledSqrtPriceX96_0 = uint256(sqrtPriceX96_0) >> 48;

        // Perform division with the scaled value
        uint256 temp = FullMath.mulDiv(scaledSqrtPriceX96_0, 1 << 144, sqrtPriceX96_1); // (sqrtPriceX96_0 / 2^48) * (2^144 / sqrtPriceX96_1)
        // before scaling was
        //uint256 temp = FullMath.mulDiv(sqrtPriceX96_0, 1 << 96, sqrtPriceX96_1); // multiply by 2^96 to convert back to Q64.96 format

        // Check for overflow before casting to uint160
        if (temp > type(uint160).max) {
                // 0 is a flag for overflow
                return 0;
        }

        return uint160(temp);
    }

    /// @dev Private method to fetch the oracle address
    function _getOracle() private view returns (IOracle) {
        return _oracle;
    }

    function _getPoolSettings(address token0, address token1, address oracle)
        private
        view
        returns (PoolSettings memory settings)
    {
        settings.key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 0,
            tickSpacing: TickMath.MAX_TICK_SPACING,
            hooks: IHooks(oracle)
        });
        IOracle.ObservationState memory state = _getOracle().getState(settings.key);
        settings.cardinality = state.cardinality;
        settings.secondsAgos = _getSecondsAgos(settings.cardinality);
    }

    function _getPriceX128(int48[] memory tickCumulatives, uint32[] secondsAgos)
        private
        pure
        returns (uint256 priceX128)
    {
        int56 tickCumulativesDelta = int56(tickCumulatives[1] - tickCumulatives[0]);
        int24 twapTick = int24(tickCumulativesDelta / int56(secondsAgos[0]));
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(secondsAgos[0]) != 0)) twapTick--;

        uint160 sqrtPriceX96 = twapTick.getSqrtPriceAtTick();
        uint256 priceX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
    }

    function _getSecondsAgos(uint16 cardinality) private view returns (uint32[] memory) {
        // blocktime cannot be lower than 8 seconds on Ethereum, 1 seconds on any other chain
        uint16 blockTime = block.chainid == 1 ? 8 : 1;
        uint32 maxSecondsAgos = uint32(cardinality * blockTime);
        uint32[] secondsAgos = new uint32[](2);
        secondsAgos[0] = maxSecondsAgos > 300 ? 300 : maxSecondsAgos;
        secondsAgos[1] = 0;
        return secondsAgos;
    }
}