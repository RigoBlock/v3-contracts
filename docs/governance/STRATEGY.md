# Governance Strategy

The governance implementation (`RigoblockGovernance` and its mixins) is strategy-agnostic: voting
power, thresholds validation, voting period and proposal state evaluation are delegated to a
strategy contract set at initialization. The strategy can later be replaced only through a
governance proposal (`upgradeStrategy`).

`RigoblockGovernanceStrategy` is **Rigoblock's own** strategy, tailored to Rigoblock's governance:
GRG staking voting power, GRG-supply-based thresholds, a Wormhole cross-chain payload guard, and a
timestamp-based voting clock. It is not a general-purpose strategy — other projects deploying the
governance are expected to write their own strategy implementing `IGovernanceStrategy`.

## Time type contract

A governance is initialized with a `TimeType` (`Timestamp` or `Blocknumber`, declared in
`contracts/governance/types/TimeType.sol`), which selects the time reference used for the voting
window. The implementation passes the configured `timeType` to the strategy on every
`votingTimestamps(timeType)` and `getProposalState(proposal, minimumQuorum, timeType)` call.

The strategy MUST honor the following contract:

1. **Same unit in both directions.** `votingTimestamps` must express `startBlockOrTime` /
   `endBlockOrTime` in the unit matching `timeType` (timestamps for `Timestamp`, block numbers for
   `Blocknumber`), and `getProposalState` must compare them against the same reference
   (`block.timestamp` / `block.number`). Mixing references — e.g. producing block numbers at
   proposal time but comparing against `block.timestamp` — makes every proposal immediately
   "expired" relative to the comparison, collapsing the voting window. In the worst case
   (`Blocknumber` governance evaluated against timestamps) a proposal flips straight to
   `Succeeded` when the qualified majority is reached, allowing the qualifying vote and `execute`
   to land in the **same transaction** and bypassing the entire voting period.

   Correct handling of both time types is demonstrated by `MockMigrationStrategy` in
   `test/governance/GovernanceMigration.t.sol` and exercised end-to-end by
   `test/governance/Governance.TimeType.t.sol` — including block-window expiry
   (`test_Blocknumber_UnqualifiedProposal_ExpiresAfterBlockWindow`).

   **Watch the units.** Durations in Solidity literals are seconds: `7 days` is `604800`.
   For `TimeType.Blocknumber` the whole window must be denominated in blocks — a separate
   block-based period constant (e.g. `50_400` blocks for 7 days at ~12s blocks), never the
   seconds period added to `block.number`. Adding a seconds duration to a block number
   silently extends the voting window by orders of magnitude (a ~100x longer window at 12s
   blocks). Note that `votingPeriod()` takes no `timeType` input and is informational only;
   its unit follows the governance's time type (seconds for `Timestamp`, blocks for
   `Blocknumber`). The enforceable window is whatever `votingTimestamps` returns.

2. **Revert on unsupported time types.** A strategy that only supports one time type must revert
   rather than silently evaluate the other. `RigoblockGovernanceStrategy` requires
   `TimeType.Timestamp` — at initialization in `assertValidInitParams` and at runtime in
   `votingTimestamps` / `getProposalState` (`GovStrategyInvalidTimeType`). The runtime check also
   protects Rigoblock's governance against a hypothetical future implementation upgrade that
   changed the stored `timeType`: governance would brick at `propose` time instead of reopening
   the same-transaction execution hole.

3. **Initialization validation.** `assertValidInitParams` is invoked by the governance proxy
   during `initializeGovernance` (any revert aborts the deployment) and should validate every
   factory parameter the strategy depends on, including `timeType`.

The governance mixins hold up their side of the contract generically: `MixinVoting.propose` stores
the strategy-produced start/end values, and `MixinVoting._castVote` closes the voting window in the
governance's own unit (`block.timestamp` or `block.number`) when the qualified majority is reached,
so execution is only possible in a later unit. Everything that depends on the strategy's evaluation
— the state machine — is the strategy's responsibility.

## RigoblockGovernanceStrategy specifics

- **Voting power**: current-epoch delegated GRG stake (`IStaking.getOwnerStakeByStatus`).
- **Qualified majority**: `3 * votesFor > 2 * globalDelegatedStake && votesFor >= minimumQuorum`.
- **Voting period**: `min(7 days, staking epoch duration)`, anchored to the current epoch's earliest
  end time; voting always starts at least one second in the future to prevent same-block upgrades.
- **Thresholds**: proposal threshold between 1% and 2% of GRG total supply (hard floor 20,000 GRG
  off mainnet); quorum threshold between 4% and 10% (hard floor 100,000 GRG off mainnet).
- **Cross-chain proposals** (Wormhole): only from Ethereum mainnet, only via
  `publishMessage(uint32,bytes,uint8)`, never targeting the local chain, and always with zero
  value — the wrapper `action.value` and every inner payload action's `value` are validated at
  proposal time, as the governance holds no native balance on receiver chains (the Wormhole fee
  is attached at execution time). See `docs/wormhole/GOVERNANCE_CROSSCHAIN.md`.

## Governance modes

The strategy is deployed with a `GovernanceMode` (`contracts/governance/types/GovernanceTypes.sol`),
fixed per chain in `governanceMode` inside `chainConfig` (`src/utils/constants.ts`). The deploy
script (`src/deploy/deploy_governance.ts`) reverts when the mode is not configured for a chain.

| Chain                                                | Mode       |
| ---------------------------------------------------- | ---------- |
| Ethereum mainnet (1)                                 | `Sender`   |
| Arbitrum, Optimism, Polygon, Unichain, Base, Sepolia | `Dual`     |
| BSC (56), HyperEVM (999)                             | `Receiver` |

The mode is validated only at deployment time. The deploy script is authoritative for the
chain-to-mode mapping and reverts when the configured mode is missing, unknown, or not the
expected one for the chain (mainnet → `Sender`, HyperEVM and BSC → `Receiver`, every other
chain → `Dual`), so a new chain cannot be wired with an invalid or unintended configuration as
long as the canonical deploy path (`deploy_governance.ts`) is used. The strategy contract
itself carries no chain check — its only mode gate is that crosschain _sending_ requires
`Sender`. An `upgradeStrategy` swap to a misconfigured strategy would only change
local-governance behavior, never the crosschain receiver path, and would be visible on-chain
before any local proposal is created.

Sending and receiving are gated at two independent layers. The strategy's mode decides who may
create crosschain proposals (only `Sender`); the receiver mixin independently pins the
trusted emitter to Wormhole chain id 2 (Ethereum mainnet) as an implementation constant
(`MixinConstants.sol`), so a strategy swap can never re-point which chain's governance is
trusted — a message emitted by any other chain's governance proxy is rejected regardless of
the local strategy.

- **Sender** (mainnet): local GRG voting, plus crosschain sending — a local proposal may
  contain Wormhole `publishMessage` actions (gated by `beforePropose`), which receivers execute.
- **Dual**: local GRG voting plus crosschain receiving. Local proposals pass through
  `beforePropose` unchanged unless they target the Wormhole contract, which reverts
  (`GovCrosschainNotSender`) — only the `Sender` governance sends.
- **Receiver** (BSC, HyperEVM): managed exclusively from mainnet; local governance is disabled
  and every staking interaction is skipped, so the strategy works even where no staking system
  exists (HyperEVM):
  - `beforePropose`, `beforeExecute` and `votingTimestamps` revert `GovLocalGovernanceDisabled`
    — no local proposal can be created or executed.
  - `getVotingPower` returns 0 and `getProposalState` returns `Defeated` without reading
    staking; `votingPeriod` returns the 7-day default. These are read methods and must not
    revert, but they can never open a local path: `Defeated` can never satisfy the
    `Succeeded` gate in `execute`, and the governance implementation reverts for non-stored
    proposals before reaching the strategy, so the values are only observable on direct
    strategy calls.
  - `assertValidInitParams` and the threshold validators skip the GRG-supply bounds (thresholds
    are inert on chains without local voting). The validators early-return rather than revert
    because a mainnet-sent crosschain `updateThresholds` action must not revert and brick the
    whole VAA batch.
  - The crosschain receiver path (`receiveMessage`) is unaffected: it reads the strategy only
    for `wormhole()` / `wormholeChainId()` and never touches staking.

The staking proxy address is ignored in receiver mode — it may be the zero address on chains
without staking (HyperEVM), or a real but retired one (BSC).

Upgrading a live governance between modes is a strategy swap via `upgradeStrategy`: deploy the
new strategy for the chain, then execute a single proposal with `upgradeImplementation` (only
if the implementation changed) and `upgradeStrategy` — never split the two across proposals.
