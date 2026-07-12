# Solidity API

## EGmxCallback

GMX v2 order-execution callback extension. Records claimable collateral
 rebates and tracked markets in pool storage so NAV remains accurate after full
 closes, liquidations, and ADL.

_Runs as an extension (always delegatecalled). Only GMX controller contracts
 may invoke the callback handler._

### NotGmxController

```solidity
error NotGmxController()
```

### InvalidCallbackAccount

```solidity
error InvalidCallbackAccount()
```

### NotArbitrum

```solidity
error NotArbitrum()
```

### constructor

```solidity
constructor() public
```

### onlyGmxController

```solidity
modifier onlyGmxController()
```

### afterOrderExecution

```solidity
function afterOrderExecution(bytes32, struct EventUtils.EventLogData orderData, struct EventUtils.EventLogData) external
```

Called by GMX after an order affecting this pool is executed.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
|  | bytes32 |  |
| orderData | struct EventUtils.EventLogData | Event log data describing the order. |
|  | struct EventUtils.EventLogData |  |

