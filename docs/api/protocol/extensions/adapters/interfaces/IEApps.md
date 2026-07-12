# Solidity API

## IEApps

### getAppTokenBalances

```solidity
function getAppTokenBalances(uint256 packedApplications) external returns (struct ExternalApp[] appBalances)
```

Returns token balances owned in a set of external contracts.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| packedApplications | uint256 | The uint encoded bitmap flags of the active applications. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| appBalances | struct ExternalApp[] | The arrays of lists of token balances grouped by application type. |

### getUniV4TokenIds

```solidity
function getUniV4TokenIds() external view returns (uint256[] tokenIds)
```

Returns the pool's Uniswap V4 active liquidity positions.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| tokenIds | uint256[] | Array of liquidity position token ids. |

