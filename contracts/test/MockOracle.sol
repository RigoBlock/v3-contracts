// SPDX-License-Identifier: Apache 2.0-or-later
pragma solidity >0.7.0 <0.9.0;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IOracle} from "../protocol/interfaces/IOracle.sol";
import {Observation} from "../protocol/types/Observation.sol";

contract MockOracle {
    uint160 private constant ONE_X96 = 2 ** 96;

    mapping(PoolId => Observation[65535]) public observations;
    mapping(PoolId => IOracle.ObservationState) public states;

    // we preserve same state as default pool id, so we get same results
    function initializeObservations(PoolKey calldata poolKey) external {
        PoolId id = poolKey.toId();
        states[id] = IOracle.ObservationState({index: 1, cardinality: 2, cardinalityNext: 2});
        uint32 initialTimestamp = uint32(block.timestamp);
        uint32 secondTimestamp = initialTimestamp + 1;
        observations[id][0] = Observation({
            blockTimestamp: initialTimestamp,
            prevTick: int24(100),
            tickCumulative: int48(0),
            secondsPerLiquidityCumulativeX128: uint144(0),
            initialized: true
        });

        observations[id][1] = Observation({
            blockTimestamp: secondTimestamp,
            prevTick: int24(200),
            tickCumulative: int48(int24(100) * int32(1)),
            secondsPerLiquidityCumulativeX128: uint144(ONE_X96 * 1),
            initialized: true
        });
    }

    function getObservation(
        PoolKey calldata key,
        uint256 index
    ) external view returns (Observation memory observation) {
        observation = observations[key.toId()][index];
    }

    function getState(PoolKey calldata key) external view returns (IOracle.ObservationState memory state) {
        state = states[key.toId()];
    }

    function observe(
        PoolKey calldata key,
        uint32[] calldata secondsAgos
    ) external view returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s) {
        tickCumulatives = new int48[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint144[](secondsAgos.length);
        uint32 currentTimestamp = uint32(block.timestamp);
        PoolId poolId = key.toId();

        for (uint256 i = 0; i < secondsAgos.length; i++) {
            uint32 targetTimestamp = currentTimestamp - secondsAgos[i];

            // Find the closest observation before or at the target timestamp
            Observation memory closestObservation;
            for (uint256 j = 0; j < states[poolId].cardinality; j++) {
                if (
                    observations[poolId][j].blockTimestamp <= targetTimestamp &&
                    (observations[poolId][j].blockTimestamp == targetTimestamp ||
                        j == states[poolId].cardinality - 1 ||
                        observations[poolId][j + 1].blockTimestamp > targetTimestamp)
                ) {
                    closestObservation = observations[poolId][j];
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
