# Governance Strategy

The governance implementation (`RigoblockGovernance` and its mixins) is strategy-agnostic: voting
power, voting window, thresholds validation and proposal state evaluation are delegated to a
strategy contract set at initialization. The strategy can later be replaced only through a
governance proposal (`upgradeStrategy`).

`RigoblockGovernanceStrategy` is **Rigoblock's own** strategy, tailored to Rigoblock's governance:
GRG staking voting power, GRG-supply-based thresholds, a Wormhole cross-chain payload guard, and a
timestamp-based voting clock. It is not a general-purpose strategy — other projects deploying the
governance are expected to write their own strategy implementing `IGovernanceStrategy`.

## Strategy hooks

The implementation talks to the strategy exclusively through hooks and read methods. Hooks carry
both validation and data: the governance does not ask the strategy for values it can pass back
later — the hook returns them at the moment they are fixed.

| Hook / method      | When                          | What it does                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ------------------ | ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `validateParams`   | proxy initialization          | Validates the factory parameters (name, time type, thresholds on the sender). Called directly after an interface-conformance probe, so the strategy's own errors surface at the initializer level (the legacy proxy constructor masks them into a panic; see the initializer tests).                                                                                                                                                                                                                                                                                                                                                                  |
| `beforePropose`    | inside `propose`, once        | Validates and optionally modifies the actions (Wormhole payload guard) **and returns the proposal's fixed voting window**. May roll the staking clock, so it is not a view.                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `beforeVote`       | inside every `castVote`       | Called before every vote with the proposal's current extra data; returns the total voting power the strategy recognizes at vote time and must never revert the vote. The governance stores the return as the proposal's snapshot — the qualified-majority denominator for the proposal's whole life — **once, on the first vote only**; once a snapshot exists the return is ignored, and implementations return the stored value unchanged and skip any expensive work. Not a view: the sender rolls the staking clock best-effort pre-snapshot so the snapshot and all votes share one epoch — post-snapshot votes perform no staking calls at all. |
| `beforeExecute`    | inside `execute`, once        | Returns the actions as they should be executed (the sender attaches the Wormhole message fee).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `getProposalState` | every state read              | Full state machine. Receives the stored proposal (with its `executed` flag — executed is terminal and reported first), proposer, snapshotted quorum and snapshotted voting power, and the governance's `timeType`.                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `getVotingPower`   | proposer gate and vote weight | Current voting power of an account.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `votingPeriod`     | informational                 | Period duration in the governance's time unit; the enforceable window is the one `beforePropose` returned.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `wormhole`         | cross-chain receive path      | The Wormhole core address. The local Wormhole chain id is not strategy state: it is read from the core contract's `chainId()` at the point of use.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |

Earlier interface generations had the governance pull these values with separate calls —
`votingTimestamps(timeType)`, `totalVotingPower()` and the `assertValidProposalThreshold` /
`assertValidQuorumThreshold` validators. They were removed: the hooks carry the data instead.
The voting window is computed once at propose time and stored in the proposal as fixed
pointers — not a rolling view re-evaluated per call — and threshold updates are validated at
execution time: `MixinUpgrade.updateThresholds` calls `validateParams` on the post-update
parameters against the live GRG supply, so supply drift between proposal and execution is
caught where the values are written.

## Time type contract

A governance is initialized with a `TimeType` (`Timestamp` or `Blocknumber`, declared in
`contracts/governance/types/TimeType.sol`), which selects the time reference used for the voting
window. The implementation passes the configured `timeType` to `getProposalState`; the window
itself is whatever `beforePropose` returned at proposal time.

The strategy MUST honor the following contract:

1. **Same unit in both directions.** `beforePropose` must express the returned
   `startBlockOrTime` / `endBlockOrTime` in the unit matching the governance's `timeType`
   (timestamps for `Timestamp`, block numbers for `Blocknumber`), and `getProposalState` must
   compare them against the same reference (`block.timestamp` / `block.number`). Mixing
   references — e.g. producing block numbers at proposal time but comparing against
   `block.timestamp` — makes every proposal immediately "expired" relative to the comparison,
   collapsing the voting window. In the worst case (`Blocknumber` governance evaluated against
   timestamps) a proposal flips straight to `Succeeded` when the qualified majority is reached,
   allowing the qualifying vote and `execute` to land in the **same transaction** and bypassing
   the entire voting period. Because `beforePropose` does not receive `timeType`, a strategy
   inherently supports the one time type its governance was configured with — it cannot branch
   per call.

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
   `Blocknumber`). The enforceable window is whatever `beforePropose` returned.

2. **Revert on unsupported time types.** A strategy that only supports one time type must revert
   rather than silently evaluate the other. `RigoblockGovernanceStrategy` requires
   `TimeType.Timestamp` — at initialization in `validateParams` and at runtime in
   `getProposalState` (`GovStrategyInvalidTimeType`). The runtime check also
   protects Rigoblock's governance against a hypothetical future implementation upgrade that
   changed the stored `timeType`: governance would brick at `propose` time instead of reopening
   the same-transaction execution hole.

3. **Initialization validation.** `validateParams` is invoked by the governance proxy
   during `initializeGovernance` (any revert aborts the deployment) and should validate every
   factory parameter the strategy depends on, including `timeType`. The initializer first
   checks the strategy has code and answers an interface-conformance probe (`wormhole()`), then
   stores the parameters and calls `validateParams` directly, so
   the strategy's own errors surface unwrapped at the initializer level. Note the legacy proxy
   constructor asserts empty initialization returndata, which masks any custom error into a
   panic on the factory deployment path; the raw errors are asserted in
   `test/governance/Governance.Initializer.t.sol`. The proxy is address-frozen by the
   deterministic-deployment spec, so the masking is documented rather than fixed.

The governance mixins hold up their side of the contract generically: `MixinVoting.propose` stores
the strategy-produced start/end values, and `MixinVoting._countVote` closes the voting window in the
governance's own unit (`block.timestamp` or `block.number`) when the qualified majority is reached,
so execution is only possible in a later unit. Everything that depends on the strategy's evaluation
— the state machine — is the strategy's responsibility.

## RigoblockGovernanceStrategy specifics

- **Constructor**: takes `(stakingProxy, wormhole)`. The wormhole address must be a contract
  that answers a `chainId()` probe — an EOA or a non-wormhole contract reverts
  `GovStrategyInvalidWormhole` — so a strategy can never be wired to an unusable bridge.
- **Voting power**: current-epoch delegated GRG stake (`IStaking.getOwnerStakeByStatus`).
- **Qualified majority**:
  `3 * votesFor > 2 * votingPowerSnapshot && votesFor > 2 * votesAgainst && votesFor >= minimumQuorum`.
  The denominator is the total voting power the strategy returns from `beforeVote` on the
  proposal's first vote, which the governance snapshots into `_PROPOSAL_EXTRA_DATA_SLOT`
  (a single mapping value packing quorum and voting power as two uint128) — never a live staking
  read at evaluation time: epoch rollovers cannot shrink the electorate after votes are
  recorded. A proposal can only close early once it would already succeed on the vote ratio at
  the deadline. On receiver chains there is no voting at all: only a proposal created by the
  recovery address during an active recovery reads `Succeeded`.
- **Epoch consistency**: the staking clock is permissionless, so `beforePropose` attempts to roll
  a finished epoch and fixes the window at the fresh epoch's boundary (the returned start is the
  current epoch's earliest end, so the whole window lands strictly inside one epoch). The roll is
  best-effort: governance must stay operational even if `endEpoch` reverts (e.g. the staking
  scheduler is stuck), so the revert is swallowed and the window falls back to starting at the
  current timestamp — `time <= start` keeps the proposal `Pending` during the propose block,
  so it becomes voteable from the next block. `beforeVote` receives the proposal's extra data and
  repeats the same best-effort roll before the first vote only, ahead of the snapshot read (see the
  mid-window rolls bullet). The voting
  period is `min(epochDuration - 1, 7 days)`: the one-second margin
  keeps the window strictly inside the epoch it starts in, whenever the epoch cannot roll.
- **Mid-window rolls**: the staking clock is permissionless, so a finished epoch can be rolled by
  anyone at any time — including inside a voting window. The roll is harmless: the first vote
  re-rolls best-effort before the snapshot is stored, so the snapshot and every vote land in the
  same epoch. Proof: the window starts when the epoch becomes rollable (`start` is the epoch's
  earliest end and votes require `time > start`), so at first-vote time `F` either nobody rolled
  yet — the first vote's own roll succeeds and snapshot and votes share the new epoch — or
  someone already rolled, in which case the first vote's roll is a no-op or harmlessly reverts
  and the snapshot is the post-roll epoch either way. No roll can land after the first vote and
  still precede another vote: a roll at `t` creates a boundary at `t + epochDuration`, and
  `t > start` with period `<= epochDuration - 1` puts that boundary past `end`. Same-block
  orderings are consistent either way (roll-then-vote and vote-with-internal-roll both snapshot
  the freshest epoch). Governance votes never roll post-snapshot (the hook returns early once
  `votingPower != 0`), so any post-snapshot clock movement requires a direct `endEpoch` on the
  staking proxy. The genuine residual is the stuck-at-first-vote case below.
- **Voting window**: returned by `beforePropose` and stored in the proposal — fixed pointers,
  not a rolling view. `votingPeriod()` (`min(7 days, epoch duration - 1)`) is informational.
- **Thresholds**: proposal threshold between 1% and 2% of GRG total supply (hard floor 20,000 GRG
  off mainnet); quorum threshold between 4% and 10% (hard floor 100,000 GRG off mainnet). Bounds
  are enforced in `validateParams`, which runs at initialization and, for updates, at execution
  time: `MixinUpgrade.updateThresholds` builds the post-update parameter set and calls
  `validateParams` against the live supply, so a proposal carrying out-of-bounds
  `updateThresholds` values passes `propose` and voting but reverts when executed — including
  when supply inflation drifted a stored threshold out of range since it was set.
  `beforePropose` performs no threshold checks.
- **Error-handling policy**: the staking proxy is a trusted, governance-owned contract, and the
  policy on `try/catch` is deliberate even though it is not uniform. Both `try/catch`es in the
  strategy wrap the `endEpoch` **write** (in `_rollEpochIfStale` and in `beforeVote`): a refused
  roll is a normal transient state (unfinalized staking pools delaying epoch finalization), not a
  fault, and governance must never get stuck because staking cannot roll. Every staking
  **view** read (`getOwnerStakeByStatus`, `epochDurationInSeconds`, `getGrgContract`,
  `getCurrentEpochEarliestEndTimeInSeconds`, `getGlobalStakeByStatus`) is a
  direct call: if one reverts, staking is genuinely broken and no local handling saves
  governance anyway — the revert surfaces as-is.
- **Reentrancy guard**: the governance entry points `propose`, `castVote` (all signature paths
  funnel through the internal vote junction), `execute` and `receiveMessage` carry the protocol's
  transient reentrancy guard (`ReentrancyGuardTransient`, EIP-1153), so a flawed upgradeable
  strategy cannot reenter the governance from inside a hook: the nested call reverts before it
  can touch state and the outer transaction unwinds.
- **Cross-chain proposals** (Wormhole): only from Ethereum mainnet, only via
  `publishMessage(uint32,bytes,uint8)`, never targeting the local chain, and always with zero
  value — the wrapper `action.value` and every inner payload action's `value` are validated at
  proposal time, as the governance holds no native balance on receiver chains (the Wormhole fee
  is attached at execution time). The local Wormhole chain id is read from the core contract's
  `chainId()` at the point of use, not held in strategy state. See
  `docs/wormhole/GOVERNANCE_CROSSCHAIN.md`.

### Known limitation: stuck at first vote, un-sticks mid-window (by design)

The genuine residual of the first-vote roll: the staking epoch is **stuck at the proposal's
first vote** (e.g. pool-finalization delays make `endEpoch` revert, so the try/catch swallows
it and the snapshot freezes at the pre-roll electorate) **and** un-sticks mid-window. Because
governance votes never roll the epoch once the snapshot exists, the mid-window promotion now
requires a **direct external `endEpoch` on the staking proxy** (the clock is permissionless, so
anyone can send it). Post-roll votes then carry new-epoch voting power against the frozen
snapshot.

The mismatch is bounded:

- votes are account-scoped (`receipt.hasVoted` per proposal and voter, voting power read live per
  account), so the same stake can appear twice in `votesFor` only via a delegation move across
  the single mid-window roll (A votes pre-roll, A's delegation moves to B at the roll, B votes
  post-roll) — it cannot appear three times;
- the effect touches only the `_qualifiedConsensus` (`Qualified`) path: the post-window
  `Succeeded` path uses quorum + `votesFor > 2 * votesAgainst` with no denominator, and
  qualifying still requires `3 * votesFor > 2 * snapshot`, so post-roll newcomers need
  majority-scale token holdings while existing voters keep full power to oppose;
- while the epoch stays stuck, the electorate is frozen instead: voting power, the `beforeVote`
  total and the snapshotted denominator are all unchanged, so governance stays fully consistent
  — not just operational.

Making the epoch roll mandatory at vote time would revert votes during finalization delays — a
self-inflicted DoS — which is why the system tolerates the mismatch instead.

Covered by `test_StuckEpoch_BalancesFrozen_FlowConsistent`,
`test_StuckEpoch_SecondVote_DoesNotMoveSnapshot`,
`test_StuckEpoch_QualifiedAgainstFrozenSnapshot`,
`test_VotingPower_FirstVoteRolls_UnrolledEpoch_SnapshotInNewEpoch`,
`test_VotingPower_PreFirstVoteRoll_Absorbed_SnapshotInPostRollEpoch` and
`test_VotingPower_StuckAtFirstVote_UnsticksMidWindow_SameStakeCountedTwice` (the mid-window roll
is a direct `endEpoch` on the staking proxy: governance votes no longer roll post-snapshot).
Hook semantics per vote with zero post-snapshot staking calls are covered by
`test_BeforeVoteHook_CalledPerVote_SnapshotStoredOnce` and
`test_BeforeVoteHook_NoStakingCalls_AfterSnapshot`.

## Governance modes

The chain's mode (sender vs receiver) exists only as the TypeScript deployment mapping — the
`GovernanceMode` enum and the per-chain `governanceMode` config field were removed — and each
mode maps to a dedicated strategy contract:

| Chain                        | Mode       | Strategy                      |
| ---------------------------- | ---------- | ----------------------------- |
| Ethereum mainnet (1)         | `Sender`   | `RigoblockGovernanceStrategy` |
| every other configured chain | `Receiver` | `WormholeReceiverStrategy`    |

The deploy script (`src/deploy/deploy_governance.ts`) is authoritative for the mapping: it
derives the mode from `GOVERNANCE_HUB_CHAIN` (`src/utils/constants.ts`) — a chain is the
sender iff it is the hub — and validates that the hub chain's config actually carries a
Wormhole core address and a `wormholeChainId`, so the hub cannot be wired with an incomplete
configuration. There is no per-chain mode field left to disagree with the derivation. Splitting
the modes into two contracts removes every runtime mode branch: each strategy implements
exactly one behavior, the constructor cannot be handed a contradictory mode/recovery
combination, and the receiver contract is small enough to audit on its own.

Sending and receiving are gated at two independent layers. Only the sender strategy can create
crosschain proposals; the receiver mixin independently pins the trusted emitter to the hub
chain's Wormhole chain id (2 = Ethereum mainnet) via an implementation immutable
(`_hubWormholeChainId` in `MixinImmutables.sol`), so a strategy swap can never re-point
which chain's governance is trusted — a message emitted by any other chain's governance proxy
is rejected regardless of the local strategy. The value is a constructor argument of the
governance implementation, set at deployment from `GOVERNANCE_HUB_CHAIN`'s `wormholeChainId`
config field and identical on every chain, so the deterministic implementation address is
unchanged; it lives in the implementation, not in the strategy constructor, because it must not
be strategy-upgradeable. It is also the only Wormhole id configured anywhere: Wormhole ids
exist on the wire (VAA fields), no on-chain EVM-chainid↔Wormhole-chainid conversion exists
(the SDK's `Chains.sol` is compile-time constants only), and every other Wormhole id —
including the local one — is read from the Wormhole core contract's `chainId()` at runtime.

- **Sender** (`RigoblockGovernanceStrategy`, mainnet only): staking-backed local GRG voting
  plus crosschain sending — a local proposal may contain Wormhole `publishMessage` actions
  (gated by `beforePropose`), which receivers execute.
- **Receiver** (`WormholeReceiverStrategy`, every other chain): managed exclusively from
  mainnet; local governance is fail-closed and the strategy never reads staking, so it works
  even where no staking system exists (e.g. HyperEVM):
  - `beforePropose` reverts `GovLocalGovernanceDisabled` unless a recovery is active — no
    local proposal can be created outside a recovery — and reverts `GovCrosschainNotSender`
    for any action targeting the Wormhole core: a wormhole action in a recovery batch would
    revert on the message fee at execution time, leaving the proposal stuck in `Succeeded`
    with no cancellation path (cancel requires `Pending`). Cross-chain messages execute
    wormhole actions without going through `beforePropose`, so the fail-fast blocks only the
    local path. `beforeExecute` is a pure pass-through (actions only execute from
    `Succeeded`, and a wormhole action can no longer be proposed).
  - `getVotingPower` returns 0 (or `type(uint96).max` for the recovery address while a
    recovery is active) and `getProposalState` is proposer-based: a proposal whose proposer
    is the recovery address returns `Succeeded` while a recovery is active, everything else
    returns `Defeated` — without reading staking. Executed is terminal and reported first:
    a proposal that was executed before the recovery window cleared stays `Executed`. The
    voting window is empty — `beforePropose` returns `(block.timestamp, block.timestamp)`
    and `votingPeriod()` is 0 — so a non-recovery proposal is never votable. `beforeVote`
    returns the recognized total — `type(uint96).max` during an active recovery (mirroring
    `getVotingPower`), 0 otherwise: returning 0 during a recovery would alias the governance's
    not-yet-snapshotted sentinel. The hook is unreachable in practice: receiver proposals are
    never `Active` (recovery proposals read `Succeeded` at creation, all others `Defeated`),
    so the Governor rejects every vote and no snapshot is ever taken on-chain. These are read
    methods and must not revert, but they
    can never open a local path: `Defeated` can never satisfy the `Succeeded` gate in
    `execute`, and the governance implementation reverts for non-stored proposals before
    reaching the strategy, so the values are only observable on direct strategy calls.
  - `validateParams` validates the governance name and bounds both thresholds to
    `0 < threshold <= type(uint96).max`: recovery voting power is hardcoded at
    `type(uint96).max`, so a threshold above the cap makes the recovery path unreachable and
    a zero threshold opens spam proposals during a recovery. The bounds also cover
    `MixinUpgrade.updateThresholds` at execution time, so a crosschain `updateThresholds`
    reverts on out-of-bounds values like any invalid action — legitimate sender-proposed
    values (1–10% of GRG supply) are far inside the cap, so VAA batches are unaffected.
  - The crosschain receiver path (`receiveMessage`) is unaffected: it reads the strategy only
    for `wormhole()` and never touches staking.
  - The constructor takes `(wormhole, governanceProxy, recoveryAddress)`. The wormhole
    address must be a contract that answers a `chainId()` probe (reusing
    `GovRecoveryAddressZero`); recoveryAddress must be non-zero, and governanceProxy must
    have code — an EOA could never deliver a recovery veto, and there is no probeable
    interface at construction time, so `code.length` is the only on-chain check (reverts
    `GovRecoveryInvalidProxy`, covering the zero address too). Correctness-of-address is
    off-chain's job: the deploy script verifies the governance
    proxy address appears in the deployed strategy bytecode. The
    strategy carries the recovery escape hatch:
    after a 60-day challenge window with no mainnet veto, the recovery address can drive the
    ordinary local proposal flow — the proposal reads `Succeeded` immediately at creation
    (proposer-based) and is executable at the next block. Error ownership:
    `IGovernanceStrategy` declares the shared threshold errors
    (`GovStrategyInvalidProposalThreshold`, `GovStrategyInvalidQuorumThreshold`) — the two
    strategies enforce different ranges (sender: 1–2% / 4–10% of GRG supply; receiver:
    `0 < threshold <= type(uint96).max`) behind the same selectors — while the sender-only
    crosschain errors (`GovCrosschain*`) and `GovStrategyInvalidTimeType` live in
    `RigoblockGovernanceStrategy`, and the recovery errors and events live in
    `strategies/interfaces/IWormholeReceiverStrategy.sol`. See RECOVERY.md for the full design.

Upgrading a live governance between modes is a strategy swap via `upgradeStrategy`: deploy the
new strategy for the chain, then execute a single proposal with `upgradeImplementation` (only
if the implementation changed) and `upgradeStrategy` — never split the two across proposals.

**Migration note.** With Dual mode removed, upgrading Arbitrum, Optimism, Base, Unichain or
Polygon to this governance train replaces their existing local staking governance with pure
receiver governance: local proposals become possible only through the recovery path, and
day-to-day execution arrives exclusively from the hub chain via Wormhole. This is intentional
— it is what enables offboarding L2 staking — but operators must know that local governance
disappears on those chains when the upgrade executes.

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
