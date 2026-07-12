# Solidity API

## ECrosschain

This extension manages NAV integrity when receiving tokens from cross-chain sources.

_Called via delegatecall from pool. Can be called by Across messages, Escrow contracts, or anyone with tokens to donate.
Direct calls will fail naturally because the contract does not implement `updateUnitaryValue`._

### CallerTransferAmount

```solidity
error CallerTransferAmount()
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

