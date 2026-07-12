# Solidity API

## IOracle

### ObservationState

```solidity
struct ObservationState {
  uint16 index;
  uint16 cardinality;
  uint16 cardinalityNext;
}
```

### increaseCardinalityNext

```solidity
function increaseCardinalityNext(struct PoolKey key, uint16 cardinalityNext) external returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew)
```

### getObservation

```solidity
function getObservation(struct PoolKey key, uint256 index) external view returns (struct Observation observation)
```

### getState

```solidity
function getState(struct PoolKey key) external view returns (struct IOracle.ObservationState state)
```

### observe

```solidity
function observe(struct PoolKey key, uint32[] secondsAgos) external view returns (int48[] tickCumulatives, uint144[] secondsPerLiquidityCumulativeX128s)
```

