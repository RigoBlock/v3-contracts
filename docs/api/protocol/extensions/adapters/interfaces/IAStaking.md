# Solidity API

## IAStaking

### stake

```solidity
function stake(uint256 amount) external
```

Stakes an amount of GRG to own staking pool. Creates staking pool if doesn't exist.

_Creating staking pool if doesn't exist effectively locks direct call._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| amount | uint256 | Amount of GRG to stake. |

### undelegateStake

```solidity
function undelegateStake(uint256 amount) external
```

Undelegates stake for the pool.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| amount | uint256 | Number of GRG units with undelegate. |

### unstake

```solidity
function unstake(uint256 amount) external
```

Unstakes staked undelegated tokens for the pool.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| amount | uint256 | Number of GRG units to unstake. |

### withdrawDelegatorRewards

```solidity
function withdrawDelegatorRewards() external
```

Withdraws delegator rewards of the pool.

