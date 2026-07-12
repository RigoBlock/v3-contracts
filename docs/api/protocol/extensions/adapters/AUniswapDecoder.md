# Solidity API

## AUniswapDecoder

### InvalidCommandType

```solidity
error InvalidCommandType(uint256 commandType)
```

### UnsupportedAction

```solidity
error UnsupportedAction(uint256 action)
```

### ZERO_ADDRESS

```solidity
address ZERO_ADDRESS
```

### NON_EXISTENT_POSITION_FLAG

```solidity
address NON_EXISTENT_POSITION_FLAG
```

### _uniV4Posm

```solidity
contract IPositionManager _uniV4Posm
```

### constructor

```solidity
constructor(address wrappedNative, address v4Posm) internal
```

### Parameters

```solidity
struct Parameters {
  uint256 value;
  address[] recipients;
  address[] tokensIn;
  address[] tokensOut;
}
```

### _decodeInput

```solidity
function _decodeInput(bytes1 commandType, bytes inputs, struct AUniswapDecoder.Parameters params) internal returns (struct AUniswapDecoder.Parameters)
```

_Decodes the input for a command._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| commandType | bytes1 | The command type to decode. |
| inputs | bytes | The encoded input data. |
| params | struct AUniswapDecoder.Parameters |  |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct AUniswapDecoder.Parameters | params containing relevant outputs. |

### Position

Each liquidity position has its associated hook address, which can be null if no hook is used.

```solidity
struct Position {
  address hook;
  uint256 tokenId;
  uint256 action;
}
```

### _decodePosmAction

```solidity
function _decodePosmAction(uint256 action, bytes actionParams, struct AUniswapDecoder.Parameters params, struct AUniswapDecoder.Position[] positions) internal view returns (struct AUniswapDecoder.Parameters, struct AUniswapDecoder.Position[])
```

_It cannot handle minting and increasing liquidity in the same call, as we run decoding before forwarding the call, hence the position is not
stored, and cannot return pool and position info, which are necessary to append value_

