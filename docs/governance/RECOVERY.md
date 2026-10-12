# Governance recovery (escape hatch)

Status: **implemented in `WormholeReceiverStrategy`** (strategy-only: no governance-implementation
change, no `receiveMessage` change). The receiver strategy implements the generic
`IGovernanceStrategy` hooks plus this escape hatch; the recovery errors and events live in
`strategies/interfaces/IWormholeReceiverStrategy.sol`.

## Problem

Receiver chains (every chain except the mainnet hub) have exactly one admin entrypoint: `receiveMessage`,
which accepts only VAAs whose emitter is the Ethereum mainnet governance proxy
(`MixinCrosschain`, `emitterChainId == 2`). Local governance is disabled by the strategy
(`GovLocalGovernanceDisabled`), and there is no external admin key.

If the Wormhole guardian set permanently stops signing messages for a chain — guardian
failure, or Wormhole deprecating the chain — every receiver-only governance freezes
irreversibly: no upgrades, no emitter migration, no recovery. Message expiry
(`_MESSAGE_TIMEOUT = 2 days`) and redelivery handle _transient_ failures, but nothing
recovers from permanent verification failure. This is also the chain-shutdown scenario: the
protocol intends to retire BSC (deprecated GRG), and bridge support for a deprecating chain
may disappear before the governance is wound down.

The mainnet hub does not have this problem: its local governance can re-point `wormhole()`
or upgrade contracts at any time.

## Design

A time-locked recovery by a pre-designated recovery address, implemented entirely in
`WormholeReceiverStrategy`. While Wormhole lives, the mainnet governance vetoes through
its normal cross-chain proposal flow. If no veto arrives within the challenge window, the
recovery address gains voting power on the receiver chain and recovers the governance
through the ordinary local proposal/vote/execute flow — which, on a receiver chain, only the
recovery address can drive.

### Why this works without touching the implementation

Verified against the current code:

- Voting power is read **only** through the strategy
  (`MixinState._getVotingPower` → `IGovernanceStrategy.getVotingPower`).
- The quorum is snapshotted into governance storage at proposal creation as the plain
  governance `quorumThreshold` — **no staking read**
  (`MixinVoting.sol:134`).
- Proposal state is computed **only** through the strategy
  (`MixinState._getProposalState` → `IGovernanceStrategy.getProposalState`).
- VAA-delivered actions execute with `msg.sender == governance proxy`
  (`GovernanceActionLib.execute` is a plain `call` from the governance contract), so the
  strategy can authenticate a veto by caller address alone — no VAA parsing in the
  strategy.
- `receiveMessage` and every other implementation function stay exactly as they are.

### Strategy changes

New constructor arguments (immutables, validated by the deploy script: both are required on
receiver chains, forbidden elsewhere — a chain can never ship with an unset or unintended
configuration):

- `recoveryAddress` — a Rigoblock-team address, required non-zero (`GovRecoveryAddressZero`):
  even a hand deployment cannot ship a permanently dead hatch.
- `governanceProxy` — the governance proxy, deterministically deployed at the same address on
  every chain. The strategy authenticates a recovery rejection (`rejectRecover`) against this
  address; it is constructor-wired rather than a source constant, but there is still no
  per-chain freedom to get it wrong.

New mutable storage:

- `recoveryRequestedAt` — timestamp of the pending request; 0 = none.

New functions:

- `requestRecover()` — callable only by `recoveryAddress`; reverts while a request is pending
  or a recovery is active (re-requesting an active recovery would overwrite its timestamp and
  disarm it); sets `recoveryRequestedAt = block.timestamp`; emits `RecoverRequested(timestamp)`.
- `rejectRecover()` — callable only by the governance proxy (i.e. only as an action delivered
  through `receiveMessage`); requires a pending request; resets
  `recoveryRequestedAt = 0`; emits `RecoverRejected()`.

Recovery-active condition (internal view): `recoveryRequestedAt != 0 &&
block.timestamp >= recoveryRequestedAt + RECOVERY_WINDOW`.

Mode-gated behavior changes — every existing local-governance branch becomes
`!recoveryActive` (i.e. under an active recovery the strategy behaves like a minimal
single-proposer local governance):

- `getVotingPower(account)`: under an active recovery, returns `type(uint96).max` for
  `recoveryAddress`, and 0 for everyone else. The fixed uint96 value is deliberate:
  - it exceeds any realistic proposer threshold by orders of magnitude,
  - it fits the vote receipt, which stores votes as `uint96`, without truncation,
  - and it keeps the recovery path free of external reads — the strategy never calls back
    into the governance proxy (or staking) to compute power.
- `getProposalState` is proposer-based: a proposal whose proposer is `recoveryAddress`
  returns `Succeeded` while a recovery is active, everything else returns `Defeated` — with
  no staking read in either branch. This is required, not an optimization: the sender
  consensus performs an external call to staking, so a bricked staking contract would make
  `getProposalState` revert and the recovery could never execute — in exactly the disaster
  case the hatch exists for. The proposer-based gate also cannot be pinned by an emptied
  staking contract (global delegated = 0), and the proposal state stays readable at every
  step. `execute` still enforces the ordinary `Succeeded` gate, so the recovery proposal is
  executable at the next block.
- `votingTimestamps` returns `(block.timestamp, block.timestamp)` and `votingPeriod` returns
  0 — the window is empty, so no flash-vote risk and no staking-derived start to compute:
  voting power is fixed to the recovery address, so only it can vote.
- `beforePropose`: allows non-Wormhole actions under an active recovery (reverts
  `GovLocalGovernanceDisabled` otherwise). Wormhole `publishMessage` targets are *not*
  special-cased here — that protection is the implementation's pinning of the trusted emitter
  to Wormhole chain id 2 (mainnet), which rejects a VAA published by a recovered chain no
  matter what its strategy allows (asserted by
  `test_ReceiveMessage_UnknownEmitterChain_Reverts`). A wormhole action in a recovery batch
  would simply revert on the fee at execution time (the governance proxy holds no native
  balance on receiver chains); keeping `beforePropose` gate-free means a recovery batch never
  fails on strategy validation before it can fix the bridge pointer.
- `beforeExecute`: pure pass-through.
- Threshold validators and `assertValidInitParams`: empty — receiver governance has no voting
  thresholds, so any value is accepted (`assertValidInitParams` only asserts the name is
  `"Rigoblock Governance"`). This also keeps a mainnet-sent crosschain `updateThresholds`
  action from reverting and bricking the whole VAA batch.

### Veto path (mainnet, while Wormhole is alive)

Mainnet creates a normal cross-chain proposal (exactly like any other cross-chain action)
whose single action is:

- target = the receiver chain's strategy, data = `rejectRecover()`.

No new payload types, no implementation functions, no changes to `_assertValidWormholeData`.
The veto reuses the entire existing machinery. This is the intended security boundary: the
recovery hatch is only as strong as the assumption that Wormhole works _well enough to deliver
one veto message within the window_.

**Veto latency budget.** The veto is not instant. A veto proposal waits for the next
staking-epoch boundary to start (up to ~14 days, the current mainnet epoch), then votes for
up to 7 days, then must be relayed. Worst case is roughly 3 weeks from the moment mainnet
decides to veto to the veto landing on the receiver chain. Detection of `RecoverRequested`
plus a mainnet decision must therefore land within roughly 39 days of the request (60-day
window minus ~3 weeks of worst-case veto latency) for the veto to arrive in time. Monitoring
receiver chains for `RecoverRequested` is the safety parameter of this mechanism; the
window arithmetic above is the monitoring SLA.

### Recovery flow (after the window, Wormhole dead or veto never sent)

1. `requestRecover()` was called at some point (any time; may be long before the failure).
2. Window passes with no veto.
3. Recovery address calls `propose` (passes the proposer threshold via the fixed recovery
   voting power) — the proposal reads `Succeeded` immediately at creation (proposer-based
   state), so `execute` is possible at the next block. No vote is needed. The proposal state
   is readable throughout, with or without a functioning staking system.
4. Typical recovery batch: `upgradeStrategy(freshStrategy)` — a new strategy instance with
   `recoveryRequestedAt = 0` re-arms the recovery hatch under the recovery governance's own
   chosen parameters, and optionally re-points `wormhole()` to a new bridge.

### Parameters (initial proposal)

| Parameter                     | Value                                        | Rationale                                                                                                                                                                                         |
| ----------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `RECOVERY_WINDOW`             | 60 days                                      | Mainnet notices and delivers one veto within ~2 epochs (2 weeks each) with large margin; long enough to survive congestion, short enough that a dead bridge does not freeze the chain for months. |
| `votingPeriod` under recovery | 0 (empty window)                            | The proposal reads `Succeeded` immediately at creation (proposer-based state), so no voting window ever runs — the period is inert.                                                            |
| Execution scope               | whatever the ordinary governance can execute | The recovery flows through normal `execute`, so no new execution primitive is introduced.                                                                                                         |

## Security analysis

**Defensive properties.**

- While Wormhole is alive, a compromised or rogue recovery address can always be vetoed:
  the request is visible on-chain immediately (`RecoverRequested`), and the veto is one
  normal cross-chain proposal. The only new operational duty is monitoring receiver chains.
- The mechanism does not re-enable public local governance: under an active recovery only
  the recovery address has voting power; everyone else still reads 0. Proposals, votes and
  execution remain fully on-chain and auditable.
- `receiveMessage` is untouched: the trusted-emitter check, replay protection and expiry
  are unchanged, and a recovery cannot influence which VAAs are accepted.
- Changing `recoveryAddress` requires a strategy upgrade — possible only while Wormhole is
  alive, i.e. exactly when the old address can still be vetoed.

**Residual risks (accepted).**

1. Recovery-key compromise _after_ Wormhole death = chain recovery. At that point the chain
   is already frozen; a compromised key converts "frozen" into "attacker-owned". Mitigation
   is custody (multisig, offline keys), not code.
2. False positive: a Wormhole liveness outage longer than the window while mainnet is alive
   and wishes to veto. The window is the safety parameter; a veto needs one delivered
   message, so 60+ days of total Wormhole silence is the exposure bar. Historical Wormhole outages are hours-to-days; chain deprecation (the intended case) makes veto impossible by design. Note the asymmetry in veto latency: even once mainnet decides to veto, the veto takes up to ~3 weeks to land (see "Veto latency budget" above) — the window is sized for ~39 days of detection-plus-decision margin on top of that.
3. Request spam: the recovery address can re-request immediately after a veto. Each request
   is vetoable, and the ultimate veto is a `upgradeStrategy` VAA that replaces the strategy
   outright. An optional cooldown (e.g. 30 days after a reset) can be added if this becomes
   operationally annoying.
4. Pending undelivered VAAs: a VAA produced before a strategy upgrade can still be
   delivered for up to `_MESSAGE_TIMEOUT` (2 days) after the upgrade and executes under
   then-current code. This is a property of the whole upgradeable system, not of this
   mechanism; the timeout bounds it.

**Why this does not open a governance attack.** The recovery path cannot create voting
power for anyone but the published recovery address; it cannot bypass the mainnet emitter
check; and the only party who can trigger it is the address verified off-chain in the deploy
records. The attack surface reduces to key custody and window calibration.

**State reporting.** Executed is terminal: `getProposalState` checks `proposal.executed` before the
receiver gate, so proposals executed during a recovery keep reading `Executed` after the recovery
ends (or is vetoed), on both the native and the OpenZeppelin-compatible status APIs.

## Alternatives considered

- **Implementation-level `executeRecovery`** (original spec): strictly more code in the
  contract that must not change; rejected in favor of the strategy-only design above.
- **Strategy parses the veto VAA itself** (`vetoRecovery(encodedVaa)`): unnecessary —
  `GovernanceActionLib.execute` already runs VAA actions with the governance proxy as
  `msg.sender`, so caller-address authentication is sufficient and replay/impersonation are
  impossible.
- **Recovery address in governance storage (mutable via VAA)**: weaker — a single
  compromised batch could point recovery at an attacker; also mutable state where an
  immutable suffices.
- **Second bridge (N-of-M)**: strictly stronger but a whole second integration; revisit if
  cross-chain governance traffic grows.
- **Paid relayer delivery**: relayers are a liveness layer, not an authenticity layer; they
  cannot help when guardians stop signing.

## Rollout

Strategy-only, so it can ship with any strategy redeploy train (the current
`fix/gov-crosschain-strategy` train already redeploys every strategy; whether the hatch
rides it or a follow-up train is a scope decision). Per chain: deploy strategy with
`recoveryAddress` set, verify immutables off-chain against the deploy record, then adopt it
via the governance's normal strategy upgrade. Until adopted, exposure is the status quo.

Test coverage: `test/governance/Governance.Recovery.t.sol` — auth, window boundary,
recovery with a fully bricked staking contract, immediate `Succeeded` at creation
(proposer-based state, no staking read), fixed uint96 recovery power, veto-after-request
locking, wormhole actions passing `beforePropose` under recovery (execution still fails on
the fee), and a full staking-backed → receiver strategy-switch transition (local governance
fail-closed after the switch, cross-chain receiving unaffected).
