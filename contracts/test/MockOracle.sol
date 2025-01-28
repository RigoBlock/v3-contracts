// SPDX-License-Identifier: Apache 2.0-or-later
pragma solidity >0.7.0 <0.9.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IOracle} from "../protocol/interfaces/IOracle.sol";
import {Observation} from "../protocol/types/Observation.sol";

contract MockOracle {
    uint160 private constant ONE_X96 = 2 ** 96;

    IOracle.ObservationState private _state;
    Observation[65535] _observations;

    constructor() {
        _state = IOracle.ObservationState({index: 0, cardinality: 2, cardinalityNext: 2});

        uint32 initialTimestamp = uint32(block.timestamp);
        uint32 secondTimestamp = initialTimestamp + 1;

        _observations[0] = Observation({
            blockTimestamp: initialTimestamp,
            prevTick: int24(100),
            tickCumulative: int48(0),
            secondsPerLiquidityCumulativeX128: uint144(0),
            initialized: true
        });

        _observations[1] = Observation({
            blockTimestamp: secondTimestamp,
            prevTick: int24(200),
            tickCumulative: int48(int24(100) * int32(1)),
            secondsPerLiquidityCumulativeX128: uint144(ONE_X96 * 1),
            initialized: true
        });
    }

    function getObservations(
        PoolKey calldata /*key*/,
        uint256 index
    ) external view returns (Observation memory observation) {
        observation = _observations[index];
    }

    function getState() external view returns (IOracle.ObservationState memory state) {
        state = _state;
    }

    function observe(
        PoolKey calldata /*key*/,
        uint32[] calldata secondsAgos
    ) external view returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s) {
        tickCumulatives = new int48[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint144[](secondsAgos.length);
        uint32 currentTimestamp = uint32(block.timestamp);

        for (uint i = 0; i < secondsAgos.length; i++) {
            uint32 targetTimestamp = currentTimestamp - secondsAgos[i];

            // Find the closest observation before or at the target timestamp
            Observation memory closestObservation;
            for (uint256 j = 0; j < _state.cardinality; j++) {
                if (
                    _observations[j].blockTimestamp <= targetTimestamp &&
                    (_observations[j].blockTimestamp == targetTimestamp ||
                        j == _state.cardinality - 1 ||
                        _observations[j + 1].blockTimestamp > targetTimestamp)
                ) {
                    closestObservation = _observations[j];
                    break;
                }
            }

            // Calculate cumulatives based on the closest observation
            tickCumulatives[i] = int48(closestObservation.tickCumulative);
            secondsPerLiquidityCumulativeX128s[i] = closestObservation.secondsPerLiquidityCumulativeX128;

            // Adjust for time passed since the closest observation (simplified for mock)
            if (targetTimestamp > closestObservation.blockTimestamp) {
                uint32 timeDiff = targetTimestamp - closestObservation.blockTimestamp;
                tickCumulatives[i] += int48(int24(closestObservation.prevTick) * int32(timeDiff));
                secondsPerLiquidityCumulativeX128s[i] += uint144(ONE_X96 * timeDiff);
            }
        }
    }
}
