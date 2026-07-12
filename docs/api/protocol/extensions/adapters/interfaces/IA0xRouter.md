# Solidity API

## IA0xRouter

Allows Rigoblock smart pools to execute swaps via the 0x AllowanceHolder and Settler contracts.

### DirectCallNotAllowed

```solidity
error DirectCallNotAllowed()
```

Thrown when a call is made directly to the adapter instead of via delegatecall.

### RecipientNotSmartPool

```solidity
error RecipientNotSmartPool()
```

Thrown when the swap recipient is not the smart pool.

### CounterfeitSettler

```solidity
error CounterfeitSettler(address target)
```

Thrown when the target is not a genuine 0x Settler instance.

### UnsupportedSettlerFunction

```solidity
error UnsupportedSettlerFunction()
```

Thrown when the Settler calldata has an unsupported function selector.

### InvalidSettlerCalldata

```solidity
error InvalidSettlerCalldata()
```

Thrown when the Settler calldata is too short to decode.

### InsufficientNativeBalance

```solidity
error InsufficientNativeBalance()
```

Thrown when the pool does not hold enough native balance.

### ActionNotAllowed

```solidity
error ActionNotAllowed(bytes4 actionSelector)
```

Thrown when a settler action is not in the adapter's allowlist.

_Only whitelisted DEX swap actions are permitted._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| actionSelector | bytes4 | The 4-byte selector of the rejected action. |

### OperatorMustEqualTarget

```solidity
error OperatorMustEqualTarget()
```

Thrown when operator is not the same address as target.

_AllowanceHolder stores the ephemeral allowance under `operator`. If operator differs
 from the genuine Settler (target), a malicious operator contract could consume the
 ephemeral allowance and drain pool tokens to an arbitrary address._

### TransferFromRecipientNotSettler

```solidity
error TransferFromRecipientNotSettler(address recipient)
```

Thrown when a TRANSFER_FROM action's recipient is not the Settler itself.

_Allowing an arbitrary recipient would let the pool owner drain funds._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| recipient | address | The decoded recipient address that failed the check. |

### exec

```solidity
function exec(address operator, address token, uint256 amount, address payable target, bytes data) external payable returns (bytes result)
```

Execute a swap via the 0x AllowanceHolder contract.

_The calldata is forwarded unmodified to AllowanceHolder after validation._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| operator | address | The address authorized to consume the ephemeral allowance. Must equal `target`. |
| token | address | The sell token address. |
| amount | uint256 | The sell token amount. |
| target | address payable | The 0x Settler contract address that will execute the swap. |
| data | bytes | The Settler.execute() calldata containing swap instructions. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| result | bytes | The return data from AllowanceHolder.exec. |

