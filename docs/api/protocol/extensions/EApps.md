# Solidity API

## EApps

A universal aggregator for external contracts positions.

_External positions are consolidating into a single view contract. As more apps are connected, can be split into multiple mixing.
Future-proof as can route to dedicated extensions, should the size of the contract become too big._

### UnknownApplication

```solidity
error UnknownApplication(uint256 appType)
```

### constructor

```solidity
constructor(struct EAppsParams params) public
```

The different immutable addresses will result in different deployed addresses on different networks.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| params | struct EAppsParams | Chain-specific addresses bundled into a single struct. |

### getAppTokenBalances

```solidity
function getAppTokenBalances(uint256 packedApplications) external returns (struct ExternalApp[])
```

Uses temporary storage to cache token prices, which can be used in MixinPoolValue.
Requires delegatecall.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| packedApplications | uint256 | The uint encoded bitmap flags of the active applications. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct ExternalApp[] |  |

### getUniV4TokenIds

```solidity
function getUniV4TokenIds() external view returns (uint256[] tokenIds)
```

Returns the pool's Uniswap V4 active liquidity positions.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| tokenIds | uint256[] | Array of liquidity position token ids. |

