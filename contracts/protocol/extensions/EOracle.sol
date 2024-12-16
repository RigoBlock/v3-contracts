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

contract EOracle is IEOracle {
    address private immutable _ORACLE_ADDRESS;

    constructor(address oracleHookAddress) {
        _ORACLE_ADDRESS = oracleHookAddress;
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
    function getBaseTokenValue(address token, uint256 amount, address baseToken)
        external
        view
        override
        returns (uint256 value)
    {
        PoolSettings memory settings;
        address oracleAddress = _getOracleAddress();

        if (token == address(0)) {
            settings = _getPoolSettings(address(0), baseToken, oracleAddress);
            try IOracle(oracleAddress).observe(settings.key, settings.secondsAgos) returns (int48[] memory tickCumulatives,) {
                uint256 priceX128 = _getPriceX128(tickCumulatives, settings.secondsAgos);
                value = FullMath.mulDiv(amount, priceX128, 1 << 128); // convert native to token
                return value;
            } catch {
                return value = 0; // Oracle failure or no pair available
            }
        }

        if (baseToken == address(0)) {
            // Convert directly to ETH
            settings = _getPoolSettings(address(0), token, oracleAddress);

            try IOracle(oracleAddress).observe(settings.key, settings.secondsAgos) returns (int48[] memory tickCumulatives,) {
                uint256 priceX128 = _getPriceX128(tickCumulatives, settings.secondsAgos);
                value = FullMath.mulDiv(amount, 1 << 128, priceX128); // convert token to ETH
                return value;
            } catch {
                return value = 0; // Oracle failure or no pair available
            }
        }

        // try and convert token to chain currency
        settings = _getPoolSettings(address(0), token, oracleAddress);

        try IOracle(oracleAddress).observe(settings.key, settings.secondsAgos) returns (int48[] memory tickCumulatives,) {
            uint256 priceX128 = _getPriceX128(tickCumulatives, settings.secondsAgos);
            uint256 ethAmount = FullMath.mulDiv(amount, 1 << 128, priceX128); // convert token to native

            // try and convert chain currency to base token
            settings = _getPoolSettings(address(0), baseToken, oracleAddress);

            // try to get first conversion
            try IOracle(oracleAddress).observe(settings.key, settings.secondsAgos) returns (int48[] memory tickCumulatives,) {
                uint256 priceX128 = _getPriceX128(tickCumulatives, settings.secondsAgos);
                value = FullMath.mulDiv(ethAmount, priceX128, 1 << 128); // convert native to base token
                return value;
            } catch {
                return _tryDirectPairConversion(token, amount, baseToken, settings);
            }
        } catch {
            return _tryDirectPairConversion(token, amount, baseToken, settings);
        }
    }

    /// @inheritdoc IEOracle
    function getOracleAddress() external view override returns (address) {
        return _getOracleAddress();
    }

    function hasPriceFeed(address token) external view returns (uint16 cardinality, uint16 cardinalityNext) {
        PoolSettings memory settings;
        address oracleAddress = _getOracleAddress();

        if (token == address(0)) {
            settings = _getPoolSettings(address(0), baseToken, oracleAddress);
            try IOracle(oracleAddress).observe(settings.key, settings.secondsAgos) returns (int48[] memory tickCumulatives,) {
                uint256 priceX128 = _getPriceX128(tickCumulatives, settings.secondsAgos);
                value = FullMath.mulDiv(amount, priceX128, 1 << 128); // convert native to token
                return value;
            } catch {
                return value = 0; // Oracle failure or no pair available
            }
        }
    }

    /// @dev Private method to fetch the oracle address
    function _getOracleAddress() private view returns (address) {
        return _ORACLE_ADDRESS;
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
        IOracle.ObservationState memory state = IOracle(oracle).getState(settings.key);
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

    function _tryDirectPairConversion(address token, uint256 amount, address baseToken, PoolSettings memory settings) 
        private 
        view 
        returns (uint256 value) 
    {
        (address token0, address token1) = uint160(token) < uint160(baseToken)
            ? (token, baseToken)
            : (baseToken, token);

        settings = _getPoolSettings(token0, token1, address(settings.key.hooks));

        try IOracle(address(settings.key.hooks)).observe(settings.key, settings.secondsAgos) returns (int48[] memory tickCumulatives,) {
            uint256 priceX128 = _getPriceX128(tickCumulatives, settings.secondsAgos);

            // Convert the amount based on the price
            if (token0 == token) {
                value = FullMath.mulDiv(amount, priceX128, 1 << 128);
            } else {
                value = FullMath.mulDiv(amount, 1 << 128, priceX128);
            }
            return value;
        } catch {
            // return 0 and allow continuation of nav estimate in case of oracle failure
            return value = 0; // Oracle failure or no pair available
        }
    }
}