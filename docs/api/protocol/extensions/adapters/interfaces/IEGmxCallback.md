# Solidity API

## IEGmxCallback

GMX v2 order execution callback extension interface.

### TrackedMarketAdded

```solidity
event TrackedMarketAdded(address market)
```

Emitted when a market is added to the tracked-markets set.

### ClaimableCollateralAdded

```solidity
event ClaimableCollateralAdded(bytes32 claimableCollateralKey, address token, address market, uint256 timeKey)
```

Emitted when a claimable-collateral key is recorded.

### TrackedMarketRemoved

```solidity
event TrackedMarketRemoved(address market)
```

Emitted when a market is removed from the tracked-markets set.

### ClaimableCollateralRemoved

```solidity
event ClaimableCollateralRemoved(bytes32 claimableCollateralKey)
```

Emitted when a fully-claimed collateral key is removed.

### afterOrderExecution

```solidity
function afterOrderExecution(bytes32 key, struct EventUtils.EventLogData orderData, struct EventUtils.EventLogData eventData) external
```

Called by GMX after an order affecting this pool is executed.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| key | bytes32 | The GMX order key. |
| orderData | struct EventUtils.EventLogData | Event log data describing the order. |
| eventData | struct EventUtils.EventLogData | Additional event data from GMX. |

