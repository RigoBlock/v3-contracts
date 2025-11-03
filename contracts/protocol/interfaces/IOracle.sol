// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Observation} from "../types/Observation.sol";

interface IOracle {
    /// @custom:member index The index of the last written observation for the pool
    /// @custom:member cardinality The cardinality of the observations array for the pool
    /// @custom:member cardinalityNext The cardinality target of the observations array for the pool, which will replace cardinality when enough observations are written
    struct ObservationState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    function increaseCardinalityNext(
        PoolKey calldata key,
        uint16 cardinalityNext
    ) external returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew);

    function getObservation(PoolKey calldata key, uint256 index) external view returns (Observation memory observation);

    function getState(PoolKey calldata key) external view returns (ObservationState memory state);

    function observe(
        PoolKey calldata key,
        uint32[] calldata secondsAgos
    ) external view returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s);
}
