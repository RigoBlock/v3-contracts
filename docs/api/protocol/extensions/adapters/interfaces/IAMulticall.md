# Solidity API

## IAMulticall

As per https://github.com/Uniswap/swap-router-contracts/blob/main/contracts/interfaces/IMulticallExtended.sol

### multicall

```solidity
function multicall(bytes[] data) external returns (bytes[] results)
```

Enables calling multiple methods in a single call to the contract

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| data | bytes[] | Array of encoded calls. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| results | bytes[] | Array of call responses. |

### multicall

```solidity
function multicall(uint256 deadline, bytes[] data) external payable returns (bytes[] results)
```

Call multiple functions in the current contract and return the data from all of them if they all succeed

_The `msg.value` should not be trusted for any method callable from multicall._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| deadline | uint256 | The time by which this function must be called before failing |
| data | bytes[] | The encoded function data for each of the calls to make to this contract |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| results | bytes[] | The results from each of the calls passed in via data |

### multicall

```solidity
function multicall(bytes32 previousBlockhash, bytes[] data) external payable returns (bytes[] results)
```

Call multiple functions in the current contract and return the data from all of them if they all succeed

_The `msg.value` should not be trusted for any method callable from multicall._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| previousBlockhash | bytes32 | The expected parent blockHash |
| data | bytes[] | The encoded function data for each of the calls to make to this contract |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| results | bytes[] | The results from each of the calls passed in via data |

