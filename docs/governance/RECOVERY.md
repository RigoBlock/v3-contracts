# Governance recovery (escape hatch)

Status: **implemented in `RigoblockGovernanceStrategy`** (strategy-only: no governance-implementation
change, no `receiveMessage` change).

## Problem

Receiver-only chains (HyperEVM, BSC) have exactly one admin entrypoint: `receiveMessage`,
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

Dual chains do not have this problem: their local governance can re-point `wormhole()` or
upgrade contracts at any time.

## Design

A time-locked recovery by a pre-designated recovery address, implemented entirely in
`RigoblockGovernanceStrategy`. While Wormhole lives, the mainnet governance vetoes through
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
  (`MixinVoting.sol:131`).
- Proposal state is computed **only** through the strategy
  (`MixinState._getProposalState` → `IGovernanceStrategy.getProposalState`).
- VAA-delivered actions execute with `msg.sender == governance proxy`
  (`GovernanceActionLib.execute` is a plain `call` from the governance contract), so the
  strategy can authenticate a veto by caller address alone — no VAA parsing in the
  strategy.
- `receiveMessage` and every other implementation function stay exactly as they are.

### Strategy changes

New constructor argument (immutable, validated by the deploy script: required on receiver
chains, forbidden elsewhere — a chain can never ship with an unset or unintended
configuration). The constructor additionally **zeroes the recovery address on non-receiver
chains**, so a misconfigured deployment cannot arm the recovery path even by accident, and
**zeroes the staking proxy on receiver chains**, so no staking address can ever influence a
receiver chain, whatever was passed at deploy time:

- `recoveryAddress` — a Rigoblock-team address, required on Receiver chains: the constructor
  reverts on a zero address there, so even a hand deployment cannot ship a permanently dead
  hatch. Zero elsewhere.

The governance proxy needs no constructor argument: the proxy is deterministically deployed
at the same address on every chain, so the strategy authenticates a recovery rejection
against that canonical address, hardcoded as a constant — no per-chain configuration, no
deploy-time input to get wrong.

New mutable storage:

- `recoveryRequestedAt` — timestamp of the pending request; 0 = none.

New functions:

- `requestRecover()` — callable only by `recoveryAddress`; reverts while a request is pending
  or a recovery is active (re-requesting an active recovery would overwrite its timestamp and
  disarm it); sets `recoveryRequestedAt = block.timestamp`; emits `RecoverRequested(timestamp)`.
- `rejectRecover()` — callable only by the governance proxy, whose canonical address is
  hardcoded in the strategy (i.e. only as an action delivered through `receiveMessage`, or a
  passed proposal on Dual chains); requires a pending request; resets
  `recoveryRequestedAt = 0`; emits `RecoverRejected()`.

Recovery-active condition (internal view): `recoveryRequestedAt != 0 &&
block.timestamp >= recoveryRequestedAt + RECOVERY_WINDOW`.

Mode-gated behavior changes — every existing `Receiver` branch becomes
`Receiver && !recoveryActive` (i.e. under an active recovery the strategy behaves like a
minimal single-voter local governance):

- `getVotingPower(account)`: under an active recovery, returns `type(uint96).max` for
  `recoveryAddress`, and 0 for everyone else. The fixed uint96 value is deliberate:
  - it exceeds any realistic quorum by orders of magnitude (quorums are bounded by a
    fraction of GRG supply; `type(uint96).max` is ~800x the entire GRG supply),
  - it fits the vote receipt, which stores votes as `uint96`, without truncation,
  - and it keeps the recovery path free of external reads — the strategy never calls back
    into the governance proxy (or staking) to compute power.
    One documented assumption: recovery cannot succeed if the governance's stored quorum were
    set above `type(uint96).max`. That would require mainnet to deliberately set an absurd
    threshold on the receiver chain before dying; threshold validators on sender/dual chains
    bound quorums to a fraction of supply, so this cannot arise from ordinary operation.
- `getProposalState`: under an active recovery, computes the state machine without any staking
  read. The qualified-consensus branch is evaluated with a staking-free receiver consensus
  (`votesFor >= minimumQuorum`): the recovery vote reaches `Qualified` immediately, the voting
  window closes at the qualifying vote, and the proposal is executable at the next block. This
  is required, not an optimization: the standard consensus performs an external call to
  staking, so a bricked staking contract would make `getProposalState` revert and the recovery
  could never execute — in exactly the disaster case the hatch exists for. The receiver
  consensus also removes the `3 * votesFor` overflow and cannot be pinned by an emptied
  staking contract (global delegated = 0). The proposal state stays readable at every step.
- `votingTimestamps`: under an active recovery, returns a staking-free start
  (`block.timestamp`) and the default voting period, instead of reverting. No flash-vote risk:
  voting power is fixed to the recovery address, so only it can vote.
- `beforePropose` / `beforeExecute`: allow non-Wormhole actions under an active recovery;
  Wormhole targets still revert `GovCrosschainNotSender`. This revert is **not** what protects
  the other chains — that is the implementation's pinning of the trusted emitter to Wormhole
  chain id 2 (mainnet), which rejects a VAA published by a recovered chain no matter what its
  strategy allows (asserted by `test_ReceiveMessage_UnknownEmitterChain_Reverts`), and the
  mode gate that keeps Dual chains from publishing at all. The revert exists so the recovery
  fails fast on an action that could never succeed: the governance proxy holds no native
  balance on receiver chains, so a `publishMessage` action would revert on the fee at
  execution time and brick the recovery proposal.
- `votingPeriod`: already staking-free on Receiver (returns the 7-day default); unchanged.
- Threshold validators and `assertValidInitParams`: unchanged (already staking-free on
  Receiver).

**Warning — `updateThresholds` during a recovery.** The threshold validators read GRG total
supply through staking. If staking is dead, a recovery proposal that includes an
`updateThresholds` action reverts inside the validator. The recovery flow does not need it:
change thresholds only after the recovery batch has installed a fresh strategy (which is
step 4 of the recovery flow anyway).

### Veto path (mainnet, while Wormhole is alive)

Mainnet creates a normal cross-chain proposal (exactly like any other cross-chain action)
whose single action is:

- target = the receiver chain's strategy, data = `rejectRecover()`.

No new payload types, no implementation functions, no changes to `_assertValidWormholeData`.
The veto reuses the entire existing machinery. This is the intended security boundary: the
recovery hatch is only as strong as the assumption that Wormhole works _well enough to deliver
one veto message within the window_.

### Recovery flow (after the window, Wormhole dead or veto never sent)

1. `requestRecover()` was called at some point (any time; may be long before the failure).
2. Window passes with no veto.
3. Recovery address calls `propose` (passes the threshold via the fixed recovery voting
   power), `castVote` For — the vote is a superquorum under the staking-free receiver
   consensus, so the proposal reaches `Qualified` immediately, the voting window closes, and
   `execute` is possible at the next block. The proposal state is readable throughout, with
   or without a functioning staking system.
4. Typical recovery batch: `upgradeStrategy(freshStrategy)` — a new strategy instance with
   `recoveryRequestedAt = 0` re-arms the recovery hatch under the recovery governance's own
   chosen parameters, and optionally re-points `wormhole()` to a new bridge.

### Parameters (initial proposal)

| Parameter                     | Value                                        | Rationale                                                                                                                                                                                         |
| ----------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `RECOVERY_WINDOW`             | 45 days                                      | Mainnet notices and delivers one veto within ~2 epochs (2 weeks each) with large margin; long enough to survive congestion, short enough that a dead bridge does not freeze the chain for months. |
| `votingPeriod` under recovery | existing 7-day default                       | Latency is covered by the `Qualified` shortcut: the qualifying vote closes the window, so the 7-day period never actually runs.                                                                   |
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
   message, so 45+ days of total Wormhole silence is the exposure bar. Historical Wormhole outages are hours-to-days; chain deprecation (the intended case) makes veto impossible by design.
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
recovery with a fully bricked staking contract, emptied staking (global delegated 0, GRG
total supply 1 — still qualifies immediately via the staking-free receiver consensus), fixed
uint96 recovery power, veto-after-vote locking, Wormhole-target rejection under recovery,
constructor zeroing of the staking proxy on receiver chains, and a full Dual → Receiver
strategy-switch transition (local governance fail-closed after the switch, cross-chain
receiving unaffected).
