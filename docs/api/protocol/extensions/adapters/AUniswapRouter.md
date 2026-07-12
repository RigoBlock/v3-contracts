# Solidity API

## IUniswapRouter

### execute

```solidity
function execute(bytes commands, bytes[] inputs) external payable
```

## IPermit2Forwarder

### permit2

```solidity
function permit2() external view returns (contract IAllowanceTransfer)
```

## AUniswapRouter

This contract is used as a bridge between a Rigoblock smart pool contract and the Uniswap universal router.

_This contract ensures that tokens approvals are set and removed correctly, and that recipient and tokens are validated._

### TransactionDeadlinePassed

```solidity
error TransactionDeadlinePassed()
```

Thrown when executing commands with an expired deadline

### PositionOwner

```solidity
error PositionOwner()
```

Thrown when the pool is not the position owner

### RecipientNotSmartPoolOrRouter

```solidity
error RecipientNotSmartPoolOrRouter()
```

Thrown when the pool is not the recipient

### UniV4PositionsLimitExceeded

```solidity
error UniV4PositionsLimitExceeded()
```

Thrown when the pool reached maximum number of liquidity positions

### DirectCallNotAllowed

```solidity
error DirectCallNotAllowed()
```

Thrown when a call is made to the adapter directly

### LiquidityMintHookError

```solidity
error LiquidityMintHookError(address hook)
```

Thrown when a pool hook can access liquidity deltas

### InsufficientNativeBalance

```solidity
error InsufficientNativeBalance()
```

Thrown when the pool does not hold enough balance

### PositionDoesNotExist

```solidity
error PositionDoesNotExist()
```

Thrown when the calldata contains both mint and increase for the same tokenId

### constructor

```solidity
constructor(address universalRouter, address v4Posm, address weth) public
```

### checkDeadline

```solidity
modifier checkDeadline(uint256 deadline)
```

### onlyDelegateCall

```solidity
modifier onlyDelegateCall()
```

### requiredVersion

```solidity
function requiredVersion() external pure returns (string)
```

Returns the minimum implementation version to use an external application.

_Adapters must implement it when modifying proxy state or storage._

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | string | String of the minimum supported version. |

### execute

```solidity
function execute(bytes commands, bytes[] inputs, uint256 deadline) external
```

Executes encoded commands along with provided inputs. Reverts if deadline has expired.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| commands | bytes | A set of concatenated commands, each 1 byte in length. |
| inputs | bytes[] | An array of byte strings containing abi encoded inputs for each command. |
| deadline | uint256 | The deadline by which the transaction must be executed. |

### execute

```solidity
function execute(bytes commands, bytes[] inputs) public
```

Executes encoded commands along with provided inputs.

_Only mint call has access to state, will revert with direct calls unless recipient is explicitly set to this._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| commands | bytes | A set of concatenated commands, each 1 byte in length. |
| inputs | bytes[] | An array of byte strings containing abi encoded inputs for each command. |

### modifyLiquidities

```solidity
function modifyLiquidities(bytes unlockData, uint256 deadline) external
```

Is not reentrancy-protected, as will revert in PositionManager.

_Delegatecall-only for extra safety, to pervent accidental user liquidity locking._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| unlockData | bytes | Encoded calldata containing actions to be executed. |
| deadline | uint256 | Deadline of the transaction. |

