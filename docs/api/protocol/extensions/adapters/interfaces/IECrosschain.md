# Solidity API

## IECrosschain

### TokensReceived

```solidity
event TokensReceived(address from, address token, uint256 amount, uint8 opType)
```

Emitted when cross-chain tokens are received

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| from | address | Address that initiated the cross-chain transfer (SpokePool) |
| token | address | Token received |
| amount | uint256 | Amount received (actual balance delta) |
| opType | uint8 | Operation type (0=Transfer, 1=Sync) |

### VirtualSupplyUpdated

```solidity
event VirtualSupplyUpdated(int256 adjustment, int256 newSupply)
```

Emitted when virtual supply is modified

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| adjustment | int256 | Signed adjustment (+/-) |
| newSupply | int256 | New virtual supply after adjustment |

### InvalidOpType

```solidity
error InvalidOpType()
```

### DonationLock

```solidity
error DonationLock(bool locked)
```

### BalanceUnderflow

```solidity
error BalanceUnderflow()
```

### NavManipulationDetected

```solidity
error NavManipulationDetected(uint256 expectedNav, uint256 actualNav)
```

### TokenNotInitialized

```solidity
error TokenNotInitialized()
```

### donate

```solidity
function donate(address token, uint256 amount, struct DestinationMessageParams params) external
```

Handles receiving tokens from a cross-chain message or an escrow refund.

_Called via delegatecall from pool. Callable by anyone._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| token | address | The token received on this chain. |
| amount | uint256 | The amount received. |
| params | struct DestinationMessageParams | The message params from the source calls sent to the across multicall handler. |

