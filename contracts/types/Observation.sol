pragma solidity ^0.8.0;

struct Observation {
    // the block timestamp of the observation
    uint32 blockTimestamp;
    // the previous printed tick to calculate the change from time to time
    int24 prevTick;
    // the tick accumulator, i.e. tick * time elapsed since the pool was first initialized
    int48 tickCumulative;
    // the seconds per liquidity, i.e. seconds elapsed / max(1, liquidity) since the pool was first initialized
    uint144 secondsPerLiquidityCumulativeX128;
    // whether or not the observation is initialized
    bool initialized;
}

struct ObservationState {
    uint16 index;
    uint16 cardinality;
    uint16 cardinalityNext;
}