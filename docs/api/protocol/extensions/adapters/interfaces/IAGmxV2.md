# Solidity API

## IAGmxV2

### DirectCallNotAllowed

```solidity
error DirectCallNotAllowed()
```

Thrown when the adapter is called directly instead of via delegatecall.

### NotArbitrum

```solidity
error NotArbitrum()
```

Thrown when deploying on a chain other than Arbitrum.

### InvalidIncreaseOrderType

```solidity
error InvalidIncreaseOrderType()
```

Thrown when the caller passes an order type that is not MarketIncrease.

### InvalidDecreaseOrderType

```solidity
error InvalidDecreaseOrderType()
```

Thrown when the caller passes an order type that is not a valid decrease type.

### ExecutionFeeExceedsMax

```solidity
error ExecutionFeeExceedsMax()
```

Thrown when the requested execution fee exceeds the protocol maximum (0.05 ETH).
 Prevents pool operators from accidentally (or maliciously) draining the pool's WETH balance.

### InsufficientNativeBalance

```solidity
error InsufficientNativeBalance()
```

Emitted when the pool's combined WETH + native ETH balance is insufficient to cover the execution fee.

### createIncreaseOrder

```solidity
function createIncreaseOrder(struct IBaseOrderUtils.CreateOrderParams params) external returns (bytes32 orderKey)
```

Opens or increases a leveraged position via a GMX v2 market increase order.

_Uses GMX's own CreateOrderParams. The adapter enforces safe values for receiver,
 cancellationReceiver, callbackContract, uiFeeReceiver, swapPath, executionFee,
 callbackGasLimit, shouldUnwrapNativeToken, referralCode, dataList, and orderType
 (always MarketIncrease) — caller-supplied values for these fields are ignored.
 Only addresses.market, addresses.initialCollateralToken, numbers.initialCollateralDeltaAmount,
 numbers.sizeDeltaUsd, numbers.acceptablePrice, and isLong are used from the caller._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| params | struct IBaseOrderUtils.CreateOrderParams | GMX CreateOrderParams (security-critical fields are overridden by the adapter). |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| orderKey | bytes32 | The unique key of the created GMX order. |

### createDecreaseOrder

```solidity
function createDecreaseOrder(struct IBaseOrderUtils.CreateOrderParams params) external returns (bytes32 orderKey)
```

Decreases or closes a leveraged position via a GMX v2 decrease order.

_Uses GMX's own CreateOrderParams. The adapter enforces safe values for receiver,
 cancellationReceiver, callbackContract, uiFeeReceiver, swapPath, executionFee,
 callbackGasLimit, shouldUnwrapNativeToken, referralCode, dataList, and
 decreasePositionSwapType (always NoSwap) — caller-supplied values for these fields are
 ignored. Forcing NoSwap keeps the returned collateral in the already-tracked collateral
 token. The market's directional PnL token (longToken for longs, shortToken for shorts)
 is proactively tracked at increase time, so profits returned in that token are visible
 to NAV computation even for keeper-driven closes and liquidations.
 orderType must be one of MarketDecrease, LimitDecrease, or StopLossDecrease, otherwise
 the call reverts._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| params | struct IBaseOrderUtils.CreateOrderParams | GMX CreateOrderParams (security-critical fields are overridden by the adapter). |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| orderKey | bytes32 | The unique key of the created GMX order. |

### updateOrder

```solidity
function updateOrder(bytes32 key, uint256 sizeDeltaUsd, uint256 acceptablePrice, uint256 triggerPrice, uint256 minOutputAmount, uint256 validFromTime, bool autoCancel) external
```

Updates size, price or fee of an existing pending GMX order.

_Matches the GMX ExchangeRouter selector exactly. Tops up the execution fee
 automatically (same on-chain formula as createOrder). Only limit-type orders are
 updatable; calling on MarketIncrease/Decrease reverts at GMX level._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| key | bytes32 | The unique order key to update. |
| sizeDeltaUsd | uint256 | New size delta in USD (GMX 10^30 precision). |
| acceptablePrice | uint256 | New acceptable execution price. |
| triggerPrice | uint256 | New trigger price for limit/stop-loss orders. |
| minOutputAmount | uint256 | New minimum output amount. |
| validFromTime | uint256 | New valid-from timestamp. |
| autoCancel | bool | New auto-cancel flag. |

### cancelOrder

```solidity
function cancelOrder(bytes32 key) external
```

Cancels a pending GMX order and recovers collateral / execution fees back to the pool.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| key | bytes32 | The order key to cancel. |

### claimFundingFees

```solidity
function claimFundingFees(address[] markets, address[] tokens, address receiver) external
```

Claims accumulated funding fees for one or more market/token pairs.

_Matches the GMX ExchangeRouter selector exactly. Claimed tokens are always sent to
 the pool (address(this) in delegatecall context) regardless of the `receiver` argument.
 Claimed tokens are registered in the active tokens set when they have a valid price feed._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| markets | address[] | Array of GMX market addresses to claim from. |
| tokens | address[] | Array of token addresses corresponding to each market. |
| receiver | address | Ignored — overridden to address(this) to ensure funds stay in the pool. |

### claimCollateral

```solidity
function claimCollateral(address[] markets, address[] tokens, uint256[] timeKeys, address receiver) external
```

Claims collateral freed from positions where the negative price impact threshold was exceeded.

_Matches the GMX ExchangeRouter selector exactly. Claimed tokens are always sent to
 the pool (address(this) in delegatecall context) regardless of the `receiver` argument.
 Claimed tokens are registered in the active tokens set when they have a valid price feed.
 Note: the deployed GMX ExchangeRouter reverts with an arithmetic underflow when
 claimable amount is zero — callers must only invoke this when collateral is claimable._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| markets | address[] | Array of GMX market addresses to claim from. |
| tokens | address[] | Array of token addresses corresponding to each market. |
| timeKeys | uint256[] | Array of time bucket keys identifying each claimable collateral batch. |
| receiver | address | Ignored — overridden to address(this) to ensure funds stay in the pool. |

