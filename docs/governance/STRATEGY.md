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
- **Qualified majority**:
  `3 * votesFor > 2 * votingPowerSnapshot && votesFor > 2 * votesAgainst && votesFor >= minimumQuorum`.
  The denominator is the total voting power the governance snapshots into storage on the
  proposal's first vote (`MixinVoting._countVote` writes it into `_PROPOSAL_EXTRA_DATA_SLOT`,
  a single mapping value packing quorum and voting power as two uint128), never a live staking
  read at evaluation time: epoch rollovers cannot shrink the electorate after votes are
  recorded. A proposal can only close early once it would already succeed on the vote ratio at
  the deadline. On receiver chains there is no voting at all: only a proposal created by the
  recovery address during an active recovery reads `Succeeded`.
- **Epoch consistency**: the staking clock is permissionless, so the strategy attempts to roll a
  finished epoch in `beforePropose` (the proposal starts at the fresh epoch's boundary). The
  roll is best-effort: governance must stay operational even if `endEpoch` reverts (e.g. the
  staking scheduler is stuck), so the revert is swallowed and the voting window falls back to
  starting at the next timestamp. The voting period is `min(epochDuration - 1, 7 days)`: the
  one-second margin keeps the whole voting window strictly inside the current epoch whenever
  the epoch cannot roll (window starts at a live epoch boundary). A mid-window epoch roll is
  not prevented — `endEpoch` is permissionless — but the frozen first-vote snapshot keeps it
  harmless: post-roll delegations enter the numerator, not the denominator.
- **Voting period**: `min(7 days, staking epoch duration - 1)`, anchored to the current epoch's
  earliest end time; a finished epoch is rolled forward when the proposal is created, so voting
  always starts at a live epoch boundary and never inside a dead epoch.
- **Thresholds**: proposal threshold between 1% and 2% of GRG total supply (hard floor 20,000 GRG
  off mainnet); quorum threshold between 4% and 10% (hard floor 100,000 GRG off mainnet).
- **Cross-chain proposals** (Wormhole): only from Ethereum mainnet, only via
  `publishMessage(uint32,bytes,uint8)`, never targeting the local chain, and always with zero
  value — the wrapper `action.value` and every inner payload action's `value` are validated at
  proposal time, as the governance holds no native balance on receiver chains (the Wormhole fee
  is attached at execution time). See `docs/wormhole/GOVERNANCE_CROSSCHAIN.md`.

## Governance modes

The chain's mode (sender vs receiver) exists only in the TypeScript deployment mapping — the
`GovernanceMode` enum was removed from on-chain types — and each mode maps to a dedicated
strategy contract:

| Chain                       | Mode       | Strategy                    |
| --------------------------- | ---------- | --------------------------- |
| Ethereum mainnet (1)        | `Sender`   | `RigoblockGovernanceStrategy` |
| every other configured chain | `Receiver` | `WormholeReceiverStrategy`  |

The deploy script (`src/deploy/deploy_governance.ts`) is authoritative for the mapping: it
derives the mode from `GOVERNANCE_HUB_CHAIN` (`src/utils/constants.ts`) and reverts when the
configured `governanceMode` disagrees, so a new chain cannot be wired with an invalid or
unintended configuration as long as the canonical deploy path is used. Splitting the modes
into two contracts removes every runtime mode branch: each strategy implements exactly one
behavior, the constructor cannot be handed a contradictory mode/recovery combination, and the
receiver contract is small enough to audit on its own.

Sending and receiving are gated at two independent layers. Only the sender strategy can create
crosschain proposals; the receiver mixin independently pins the trusted emitter to Wormhole
chain id 2 (Ethereum mainnet) as an implementation constant (`MixinConstants.sol`), so a
strategy swap can never re-point which chain's governance is trusted — a message emitted by
any other chain's governance proxy is rejected regardless of the local strategy.

- **Sender** (`RigoblockGovernanceStrategy`, mainnet only): staking-backed local GRG voting
  plus crosschain sending — a local proposal may contain Wormhole `publishMessage` actions
  (gated by `beforePropose`), which receivers execute.
- **Receiver** (`WormholeReceiverStrategy`, every other chain): managed exclusively from
  mainnet; local governance is fail-closed and the strategy never reads staking, so it works
  even where no staking system exists (e.g. HyperEVM):
  - `beforePropose` reverts `GovLocalGovernanceDisabled` unless a recovery is active — no
    local proposal can be created outside a recovery. `beforeExecute` is a pure pass-through.
  - `getVotingPower` returns 0 (or `type(uint96).max` for the recovery address while a
    recovery is active) and `getProposalState` is proposer-based: a proposal whose proposer
    is the recovery address returns `Succeeded` while a recovery is active, everything else
    returns `Defeated` — without reading staking. `votingPeriod` returns 0 and
    `votingTimestamps` returns `(block.timestamp, block.timestamp)`: the window is empty, so
    a non-recovery proposal is never votable. These are read methods and must not revert,
    but they can never open a local path: `Defeated` can never satisfy the `Succeeded` gate
    in `execute`, and the governance implementation reverts for non-stored proposals before
    reaching the strategy, so the values are only observable on direct strategy calls.
  - `assertValidInitParams` and the threshold validators are empty: receiver governance has
    no voting thresholds, so any value is accepted. This keeps a mainnet-sent crosschain
    `updateThresholds` action from reverting and bricking the whole VAA batch.
  - The crosschain receiver path (`receiveMessage`) is unaffected: it reads the strategy only
    for `wormhole()` / `wormholeChainId()` and never touches staking.
  - The constructor takes `(wormhole, wormholeChainId, governanceProxy, recoveryAddress)`,
    with both addresses required non-zero. The strategy carries the recovery escape hatch:
    after a 60-day challenge window with no mainnet veto, the recovery address can drive the
    ordinary local proposal flow — the proposal reads `Succeeded` immediately at creation
    (proposer-based) and is executable at the next block. The recovery errors and events
    live in `strategies/interfaces/IWormholeReceiverStrategy.sol`, not in the generic
    `IGovernanceStrategy`. See RECOVERY.md for the full design.

Upgrading a live governance between modes is a strategy swap via `upgradeStrategy`: deploy the
new strategy for the chain, then execute a single proposal with `upgradeImplementation` (only
if the implementation changed) and `upgradeStrategy` — never split the two across proposals.

## Factory and proxy address

`RigoblockGovernanceFactory.createGovernance` salts the proxy with
`keccak256(abi.encode(msg.sender, name))` only. The implementation, strategy, thresholds and
time type are read from the factory's transient storage by the proxy constructor — they are
**not** part of the proxy init code. Consequences:

- The proxy address on every chain depends only on the factory address, the deployer key
  and the name. In particular it is independent of the implementation address, so a chain
  created with a **newer governance implementation** still lands at the same proxy address
  as the other chains (same key, same `"Rigoblock Governance"` name). There is no beacon and
  no two-step upgrade: pass the current implementation and strategy as `createGovernance`
  arguments.
- Because the proxy address is chain-independent, the receiver strategy takes it as a
  constructor argument (`governanceProxy`) to authenticate a recovery rejection
  (`rejectRecover`) — it is still not part of per-chain configuration beyond the single
  constructor wiring in the deploy script.
- This is how HyperEVM is brought under the canonical governance: deploy (or reuse) the
  implementation and strategy, then `createGovernance(newImplementation, strategy, …)` from
  the same deployer key — the proxy is created already pointing at the new implementation,
  natively bonded to the passed strategy.
