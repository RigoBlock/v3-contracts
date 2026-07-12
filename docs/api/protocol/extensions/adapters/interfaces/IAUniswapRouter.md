# Solidity API

## IAUniswapRouter

### UniV4PositionAdded

```solidity
event UniV4PositionAdded(uint256 tokenId)
```

Emitted when a Uniswap V4 liquidity position token ID is tracked by the pool.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| tokenId | uint256 | The ERC-721 token ID of the newly minted V4 position. |

### UniV4PositionRemoved

```solidity
event UniV4PositionRemoved(uint256 tokenId)
```

Emitted when a tracked Uniswap V4 liquidity position token ID is removed.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| tokenId | uint256 | The ERC-721 token ID of the burned V4 position. |

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
function execute(bytes commands, bytes[] inputs) external
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

Executes a Uniswap V4 Posm liquidity transaction.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| unlockData | bytes | Encoded calldata containing actions to be executed. |
| deadline | uint256 | Deadline of the transaction. |

