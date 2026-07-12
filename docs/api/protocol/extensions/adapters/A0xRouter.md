# Solidity API

## A0xRouter

_See docs/0x/ACTION_ALLOWLIST.md for security rationale and blocked action details._

### constructor

```solidity
constructor(address allowanceHolder, address deployer) public
```

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| allowanceHolder | address | The 0x AllowanceHolder contract address (chain-specific, immutable). |
| deployer | address | The 0x Deployer/Registry contract address (same on all chains). |

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

### exec

```solidity
function exec(address operator, address token, uint256 amount, address payable target, bytes data) external payable returns (bytes)
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
| [0] | bytes |  |

