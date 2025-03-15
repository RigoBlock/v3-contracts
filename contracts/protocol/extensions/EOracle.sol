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
import {ISmartPoolImmutable} from "../interfaces/v4/pool/ISmartPoolImmutable.sol";
import {Observation} from "../types/Observation.sol";

contract EOracle is IEOracle {
    using TickMath for int24;

    address private constant _ZERO_ADDRESS = address(0);
    uint256 private constant Q96 = 2**96;
    int24 private constant UNINITIALIZED_TICK = TickMath.MIN_TICK;

    address private immutable _wrappedNative;

    IOracle private immutable _oracle;

    constructor(address oracleHookAddress, address wrappedNative) {
        _wrappedNative = wrappedNative;
        _oracle = IOracle(oracleHookAddress);
    }

    /// @inheritdoc IEOracle
    /// @dev Assumes tokens and amounts arrays have same length, as the method is used by the smart pool implementation.
    function convertTokenAmounts(
        address[] memory tokens,
        int256[] calldata amounts,
        address targetToken
    ) external view override returns (int256 convertedValue) {
        if (targetToken == _wrappedNative) {
            targetToken = _ZERO_ADDRESS;
        }

        int24 ethToTargetTokenTwap = UNINITIALIZED_TICK;
        uint256 convertedAmount;

        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == _wrappedNative) {
                tokens[i] = _ZERO_ADDRESS;
            }

            if (amounts[i] == 0) {
                continue;
            } else if (tokens[i] == targetToken) {
                // we need to run this block, as native token could be passed as active, with native as base
                convertedValue += amounts[i];
                continue;
            }

            uint256 absAmount = uint256(amounts[i] >= 0 ? amounts[i] : -amounts[i]);

            if (tokens[i] == _ZERO_ADDRESS) {
                if (ethToTargetTokenTwap == UNINITIALIZED_TICK) {
                    ethToTargetTokenTwap = getTwap(targetToken);
                }

                // Direct conversion from ETH to targetToken
                convertedAmount = _convertUsingTick(absAmount, ethToTargetTokenTwap);
            } else {
                int24 ethToTokenTwap = getTwap(tokens[i]);
                if (targetToken == _ZERO_ADDRESS) {
                    // Direct conversion from token to ETH
                    convertedAmount = _convertUsingTick(absAmount, -ethToTokenTwap);
                } else {
                    if (ethToTargetTokenTwap == UNINITIALIZED_TICK) {
                        ethToTargetTokenTwap = getTwap(targetToken);
                    }

                    int24 crossTick = -(ethToTokenTwap - ethToTargetTokenTwap);

                    if (crossTick >= TickMath.MIN_TICK && crossTick <= TickMath.MAX_TICK) {
                        convertedAmount = _convertUsingTick(absAmount, crossTick);
                    } else {
                        return 0;
                    }
                }
            }

            convertedValue += amounts[i] >= 0 ? int256(convertedAmount) : -int256(convertedAmount);
        }
    }

    function _convertUsingTick(uint256 amount, int24 tick) internal pure returns (uint256) {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96); // Q96 * Q96 = Q192
        return FullMath.mulDiv(amount, priceX192, Q96 * Q96); // Q192 / Q192 = Q0, so no need for further adjustment
    }

    /// @inheritdoc IEOracle
    /// @dev This method will return true if the last stored observation has a non-nil timestamp.
    /// @dev Adding wrapped native token requires a price feed against navite, as otherwise must warm up EApps in order
    /// to have same contract address on all chains.
    function hasPriceFeed(address token) external view returns (bool) {
        if (token == _ZERO_ADDRESS || token == _wrappedNative) {
            return true;
        } else {
            (PoolKey memory key, IOracle.ObservationState memory state) =
                _getPool(_ZERO_ADDRESS, token, _oracle);

            // try and get the last stored observation
            (Observation memory observation) = _oracle.getObservation(key, state.index);
            return observation.blockTimestamp != 0;
        }
    }

    // TODO: check if need to adjust for decimals, as per https://github.com/Uniswap/v4-periphery/blob/de15ed6da5400b3c877095ab05ff16bcda80385f/src/libraries/Descriptor.sol#L280
    /// @inheritdoc IEOracle
    function getTwap(address token) public view override returns (int24 twap) {
        PoolKey memory key;
        IOracle.ObservationState memory state;

        if (token == _ZERO_ADDRESS || token == _wrappedNative) {
            // tick = 0 implies price of 1
            return 0;
        } else {
            (key, state) = _getPool(_ZERO_ADDRESS, token, _oracle);

            // get twap from oracle
            uint32[] memory secondsAgos = _getSecondsAgos(state.cardinality);
            (int48[] memory tickCumulatives, ) = _oracle.observe(key, secondsAgos);
            return int24((tickCumulatives[1] - tickCumulatives[0]) / int56(int32(secondsAgos[0])));
        }
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

    function _getSecondsAgos(uint16 cardinality) private view returns (uint32[] memory secondsAgos) {
        // blocktime cannot be lower than 8 seconds on Ethereum, 1 seconds on any other chain
        uint16 blockTime = block.chainid == 1 ? 8 : 1;
        uint32 maxSecondsAgos = uint32(cardinality * blockTime);
        secondsAgos = new uint32[](2);
        secondsAgos[0] = maxSecondsAgos > 300 ? 300 : maxSecondsAgos;
        secondsAgos[1] = 0;
    }
}
