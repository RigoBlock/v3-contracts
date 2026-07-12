# Solidity API

## IAGovernance

### propose

```solidity
function propose(struct IGovernanceVoting.ProposedAction[] actions, string description) external
```

Allows to make a proposal to the Rigoblock governance.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| actions | struct IGovernanceVoting.ProposedAction[] | Array of tuples of proposed actions. |
| description | string | A human-readable description. |

### castVote

```solidity
function castVote(uint256 proposalId, enum IGovernanceVoting.VoteType voteType) external
```

Allows a pool to vote on a proposal.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| proposalId | uint256 | Number of the proposal. |
| voteType | enum IGovernanceVoting.VoteType | Enum of the vote type. |

### execute

```solidity
function execute(uint256 proposalId) external
```

Allows a pool to execute a proposal.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| proposalId | uint256 | Number of the proposal. |

