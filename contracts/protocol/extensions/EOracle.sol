// SPDX-License-Identifier: Apache 2.0
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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract EOracle {
    using TickMath for int24;

    address constant ORACLE_ADDRESS = address(0x123);

    // TODO: should move some logic (if makes sense) to internal method, so that can use it to verify swap token has feed
    // TODO: verify what happens when token = address(0)
    function getBaseTokenValue(address token, uint256 amount, address baseToken)
        public
        /*override*/
        returns (uint256 value)
    {
        // TODO: this condition should never be reached, as we early return in core
        if (token = baseToken) {
            return amount;
        }

        uint32[] secondsAgos = new uint32[](2);
        secondsAgos[0] = 1800; // 30 minutes
        secondsAgos[1] = 0;

        (address token0, address token1) = uint160(token) < uint160(baseToken)
            ? (token, baseToken)
            : (baseToken, token);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 0,
            tickSpacing: TickMath.MAX_TICK_SPACING,
            hooks: IHooks(ORACLE_ADDRESS)
        });
        
        // an oracle should never revert, but we want to continue nav estimate
        try IOracle(ORACLE_ADDRESS).observe(key, secondsAgos) returns (
            int48[] memory tickCumulatives,
            uint144[] memory secondsPerLiquidityCumulativeX128s
        ) { 
            if (secondsPerLiquidityCumulativeX128s > 0) {
                // Calculate TWAP for tick
                int56 tickCumulativesDelta = int56(tickCumulatives[1] - tickCumulatives[0]);

                twapTick = int24(tickCumulativesDelta / int56(secondsAgos[0]));
                // Always round to negative infinity
                if (tickCumulativesDelta < 0 && (tickCumulativesDelta % secondsAgo != 0)) twapTick--;

                // Get the price from the TWAP tick
                uint160 sqrtPriceX96 = twapTick.getSqrtPriceAtTick();
                uint256 priceX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64); // Convert to Q128.128

                // Convert the amount based on the price
                if (token0 == token) {
                    // If token is token0, we need to multiply amount by price for token1 (baseToken) amount
                    value = FullMath.mulDiv(amount, priceX128, 1 << 128);
                } else {
                    // If token is token1, we need to divide amount by price to get token0 (baseToken) amount
                    value = FullMath.mulDiv(amount, 1 << 128, priceX128);
                }
            } else {
                bool tokenIsNative = token == address(0);
                bool baseTokenIsNative = baseToken == address(0);

                if (tokenIsNative || baseTokenIsNative) {
                    // If either token or baseToken is native, we only need one oracle query
                    address nonNativeToken = tokenIsNative ? baseToken : token;
                    bool isToken0 = !tokenIsNative;  // true if token is native, false if baseToken is native

                    key = PoolKey({
                        currency0: Currency.wrap(address(0)),
                        currency1: Currency.wrap(nonNativeToken),
                        fee: 0,
                        tickSpacing: TickMath.MAX_TICK_SPACING,
                        hooks: IHooks(ORACLE_ADDRESS)
                    });

                    try IOracle(ORACLE_ADDRESS).observe(key, secondsAgos) returns (
                        int48[] memory tickCumulatives,
                        uint144[] memory secondsPerLiquidityCumulativeX128s
                    ) {
                        int56 tickCumulativesDelta = int56(tickCumulatives[1] - tickCumulatives[0]);
                        int24 twapTick = int24(tickCumulativesDelta / int56(secondsAgos[0]));
                        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(secondsAgos[0]) != 0)) twapTick--;

                        uint160 sqrtPriceX96 = twapTick.getSqrtPriceAtTick();
                        uint256 priceX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);

                        // Determine if we're converting from native to token or vice versa
                        value = isToken0 
                            ? FullMath.mulDiv(amount, priceX128, 1 << 128)  // convert native to token
                            : FullMath.mulDiv(amount, 1 << 128, priceX128); // convert token to native
                    } catch {
                        revert(OracleFailure());
                    }
                } else {
                    // Fetch prices against native currency
                    PoolKey memory keyTokenToNative = PoolKey({
                        currency0: Currency.wrap(address(0)),
                        currency1: Currency.wrap(token),
                        fee: 0,
                        tickSpacing: TickMath.MAX_TICK_SPACING,
                        hooks: IHooks(ORACLE_ADDRESS)
                    });

                    PoolKey memory keyBaseToNative = PoolKey({
                        currency0: Currency.wrap(address(0)),
                        currency1: Currency.wrap(baseToken),
                        fee: 0,
                        tickSpacing: TickMath.MAX_TICK_SPACING,
                        hooks: IHooks(ORACLE_ADDRESS)
                    });

                    try IOracle(ORACLE_ADDRESS).observe(keyTokenToNative, secondsAgos) returns (
                        int48[] memory tickCumulativesTokenToNative,
                        uint144[] memory secondsPerLiquidityCumulativeX128sTokenToNative
                    ) {
                        try IOracle(ORACLE_ADDRESS).observe(keyBaseToNative, secondsAgos) returns (
                            int48[] memory tickCumulativesBaseToNative,
                            uint144[] memory secondsPerLiquidityCumulativeX128sBaseToNative
                        ) {
                            // Calculate TWAP for both tokens against native currency
                            int56 tickCumulativesDeltaToken = int56(tickCumulativesTokenToNative[1] - tickCumulativesTokenToNative[0]);
                            int24 twapTickTokenToNative = int24(tickCumulativesDeltaToken / int56(secondsAgos[0]));
                            if (tickCumulativesDeltaToken < 0 && (tickCumulativesDeltaToken % int56(secondsAgos[0]) != 0)) twapTickTokenToNative--;

                            int56 tickCumulativesDeltaBase = int56(tickCumulativesBaseToNative[1] - tickCumulativesBaseToNative[0]);
                            int24 twapTickBaseToNative = int24(tickCumulativesDeltaBase / int56(secondsAgos[0]));
                            if (tickCumulativesDeltaBase < 0 && (tickCumulativesDeltaBase % int56(secondsAgos[0]) != 0)) twapTickBaseToNative--;

                            // Get prices from TWAP ticks
                            uint160 sqrtPriceX96Token = twapTickTokenToNative.getSqrtPriceAtTick();
                            uint256 priceX128Token = FullMath.mulDiv(sqrtPriceX96Token, sqrtPriceX96Token, 1 << 64);

                            uint160 sqrtPriceX96Base = twapTickBaseToNative.getSqrtPriceAtTick();
                            uint256 priceX128Base = FullMath.mulDiv(sqrtPriceX96Base, sqrtPriceX96Base, 1 << 64);

                            // Convert token amount to native currency
                            uint256 nativeAmount = FullMath.mulDiv(amount, 1 << 128, priceX128Token);

                            // Convert native currency amount to base token amount
                            value = FullMath.mulDiv(nativeAmount, priceX128Base, 1 << 128);
                        } catch {
                            revert(OracleFailure());
                        }
                    }
                }
            }
        } catch {
            revert(OracleFailure());
        }
    }
}