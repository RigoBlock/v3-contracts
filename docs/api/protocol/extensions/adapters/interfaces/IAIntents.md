# Solidity API

## IAIntents

### CrossChainTransferInitiated

```solidity
event CrossChainTransferInitiated(address from, uint256 destinationChainId, address inputToken, uint256 inputAmount, uint8 opType, address escrow)
```

Emitted when tokens are deposited for cross-chain transfer

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| from | address | Address that initiated the transfer |
| destinationChainId | uint256 | Destination chain ID |
| inputToken | address | Token being sent |
| inputAmount | uint256 | Amount sent |
| opType | uint8 | Operation type (0=Transfer, 1=Sync) |
| escrow | address | Escrow address receiving refunds |

### DirectCallNotAllowed

```solidity
error DirectCallNotAllowed()
```

### NullAddress

```solidity
error NullAddress()
```

### ZeroConvertedValue

```solidity
error ZeroConvertedValue()
```

### OutputAmountTooHigh

```solidity
error OutputAmountTooHigh()
```

### OutputAmountTooLow

```solidity
error OutputAmountTooLow()
```

### TokenNotActive

```solidity
error TokenNotActive()
```

### SameChainTransfer

```solidity
error SameChainTransfer()
```

### InvalidInputToken

```solidity
error InvalidInputToken()
```

### AcrossParams

```solidity
struct AcrossParams {
  address depositor;
  address recipient;
  address inputToken;
  address outputToken;
  uint256 inputAmount;
  uint256 outputAmount;
  uint256 destinationChainId;
  address exclusiveRelayer;
  uint32 quoteTimestamp;
  uint32 fillDeadline;
  uint32 exclusivityDeadline;
  bytes message;
}
```

### depositV3

```solidity
function depositV3(struct IAIntents.AcrossParams params) external
```

Executes a crosschain token transfer to across and updated virtual storage.

_Has different method selector than across depositV3 to avoid viaIr compilation._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| params | struct IAIntents.AcrossParams | Across params encoded as tuple. |

