# Solidity API

## Observation

```solidity
struct Observation {
  uint32 blockTimestamp;
  int24 prevTick;
  int48 tickCumulative;
  uint144 secondsPerLiquidityCumulativeX128;
  bool initialized;
}
```

## ObservationState

```solidity
struct ObservationState {
  uint16 index;
  uint16 cardinality;
  uint16 cardinalityNext;
}
```

