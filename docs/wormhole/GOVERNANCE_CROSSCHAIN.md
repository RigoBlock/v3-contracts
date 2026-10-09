# Wormhole Cross-Chain Governance

This document describes how Rigoblock governance on Ethereum mainnet controls
target chains such as HyperEVM through Wormhole cross-chain messages.

## Goals

- No governance proxy on the target chain.
- No staking rewards / staking proxy on the target chain.
- Any governance proposal can include actions that target the local Wormhole core contract.
- Each target-chain receiver is configured to trust a specific emitter (by default the Ethereum mainnet governance proxy), so only messages from that emitter are executed.
- Actions within one message are executed on the target chain in the exact order they
  were encoded. Across messages, only increasing sequence numbers are enforced
  (see "Ordered execution and replay protection" below), so order-sensitive
  cross-message dependencies must be batched into one message.
- Each proposal is protected against replay on every chain.
- Proposal quorum is snapshotted at creation time so future quorum changes cannot
  alter the outcome of an existing proposal (fixes [#200][issue-200]).

## Sender and receiver roles

A chain's role is expressed entirely through its governance strategy:

- **Ethereum mainnet is the only sender.** `RigoblockGovernanceStrategy.beforePropose`
  rejects Wormhole actions in any other mode (`GovCrosschainNotSender`), and the
  receiver mixin cannot run on mainnet at all (`GovReceiverLocalEmitter`, since the
  trusted emitter is mainnet itself). The trusted emitter is checked as
  `emitterAddress == address(this)`: the proxy is deployed at the same deterministic
  address on every chain, so the mainnet instance of that shared address is the only
  valid emitter.
- **Every other chain is a receiver** when its strategy has a nonzero Wormhole core
  address. Receiving is permissionless (any relayer can deliver a VAA) and independent
  of local governance.
- **Receiver chains may also self-govern.** Receiving cross-chain messages does not
  disable local proposals: a receiver-chain governance with a staking-backed strategy
  can still propose, vote and execute with its own voting power. Concretely:
  - _Arbitrum and the OP-stack chains (Optimism, Base, Unichain)_: controlled both by
    their own local governance and by Ethereum mainnet.
  - _HyperEVM, BSC, Polygon_: controlled via Ethereum mainnet only (no local voting
    power is configured).
    `test_LocalGovernance_CoexistsWithCrosschainReceive` in
    `test/governance/Governance.Crosschain.t.sol` asserts both capabilities on one
    contract.

## Architecture

```
Ethereum mainnet (sender chain)
  RigoblockGovernance proxy
    └─ MixinVoting.execute
       └─ every action is routed through RigoblockGovernanceStrategy.beforeExecute
       └─ Wormhole actions call IWormhole.publishMessage{value: messageFee}(payload)

Target chain (e.g. HyperEVM, receiver chain)
  RigoblockGovernance proxy  (same deterministic address as on mainnet)
    └─ MixinCrosschain.receiveMessage (inside the governance implementation)
       └─ parseAndVerifyVM(encodedVaa)
          └─ sequence >= nextMinimumSequence check, then execute the action batch
```

There is no dedicated receiver contract: the cross-chain receiver is a mixin of
the `RigoblockGovernance` implementation, so the governance proxy itself is the
receiver hub on each chain. Because the governance proxy is deployed at the same
deterministic address on every chain, the receiver asserts
`emitterAddress == address(this)` — no emitter address needs to be configured per
chain — and the receiver address on a new chain is known before deployment.

The `RigoblockGovernance` implementation has no constructor arguments, so it can
be deployed at the same deterministic address on every chain. The Wormhole core
address and local Wormhole chain id are stored in `RigoblockGovernanceStrategy`,
which is deployed per chain and therefore does not affect the governance
implementation address. A chain is a **receiver** when its governance strategy
has a nonzero Wormhole address; a chain with a zero Wormhole address in its
strategy does not process cross-chain messages at all.

## Native value policy

- The governance is expected to hold **no native currency and no ERC-20 tokens**,
  on every chain. Cross-chain governance is message-passing only.
- Cross-chain payloads carry **no value**: the strategy validates at proposal time
  on the sender chain that both the wrapper `action.value` and the inner payload
  `action.value` are zero (`GovCrosschainInvalidValue`).
- The Wormhole message fee (zero today, but adjustable by Wormhole) is **not part
  of the proposal**. It is attached at execution time: `beforeExecute` overrides
  the action value with a fresh `messageFee()` read, which is the only moment the
  exact fee is knowable — if it were fixed at proposal time, a fee change between
  propose and execute would brick the action. The executor pays it as part of
  `execute`'s `msg.value`.
- `MixinVoting.execute` requires `msg.value` to **equal** the summed action values:
  any excess or shortfall reverts with `GovExecutionValueMismatch(required, provided)`,
  so no surplus can be left in the governance. Note the inherited OZ `Governor` also
  brings a payable `receive()`, so a plain ETH transfer can still park funds; recovering
  them requires a governance action.

## Governance side

A cross-chain proposal is an ordinary governance proposal. Each cross-chain
action is a normal `ProposedAction`:

- `target` = the local Wormhole core contract.
- `data` = `abi.encodeCall(IWormhole.publishMessage, (nonce, encodedPayload, consistencyLevel))`.
- `value` = `0` at proposal time. The Wormhole fee is not part of the proposal;
  it is attached by the strategy at execution time (see above).

The `encodedPayload` is `abi.encode(CrossChainPayload)`:

- `targetWormholeChainId`: the destination Wormhole chain id. The receiver
  asserts this matches the local chain, so a VAA intended for another chain
  cannot be replayed here.
- `proposalId`: the mainnet proposal id that produced the message. It is
  included for auditability and off-chain indexing; replay protection is
  enforced by the ordered sequence and by atomic proposal execution on
  mainnet.
- `actions`: the batch of `ProposedAction`s to execute on the target chain, in
  order. A message may carry one action or several — the typical case of an
  adapter upgrade coupled with an implementation upgrade is a single message
  with a two-action batch, executed atomically. Actions may target external
  contracts or the governance proxy itself (implementation/strategy upgrades
  and threshold updates use the same `onlyGovernance` path as local voting).
  Every action must carry `value == 0`, validated on the sender chain at
  proposal time (see Native value policy). Wormhole does not cap the payload
  length on EVM; keep batches modest, as VAA verification cost grows with size.

Encoding is client-side: the proposer builds the `publishMessage` calldata
off-chain. The only on-chain Wormhole specificity is `beforeExecute`'s fresh fee
read. `RigoblockGovernanceStrategy` enforces, via `beforePropose`:

- Cross-chain actions are only allowed on Ethereum mainnet (`block.chainid == 1`).
- If `action.target == wormhole`, the calldata selector must be
  `IWormhole.publishMessage.selector` and the decoded `CrossChainPayload` must
  target a chain other than the local Wormhole chain id.
- The `consistencyLevel` argument must be `200` (Wormhole's finalized level):
  governance messages must reach Ethereum finality before guardian attestation
  (`GovCrosschainInvalidConsistencyLevel` otherwise).
- The wrapper `value` and every inner action `value` must be `0`
  (`GovCrosschainInvalidValue` otherwise).

## Receiver side

The receiver logic lives in `MixinCrosschain`, a mixin of the governance
implementation (`contracts/governance/mixins/MixinCrosschain.sol`). Relayers
deliver VAAs by calling `receiveMessage` on the chain's governance proxy, whose
fallback delegatecalls into the implementation. It follows the same validation
steps as the Wormhole `HelloWorld` example:

1. Parses and verifies the VAA through the Wormhole core contract read from the
   governance strategy. `parseAndVerifyVM` checks the guardian-set signature
   proof. Forged or malformed VAAs return `valid == false` and the receiver
   reverts with the reason provided by Wormhole.
2. Asserts the emitter chain id (`2`, Ethereum) and emitter address
   (`address(this)`, identical to the governance proxy on every chain) match the
   trusted sender-chain governance proxy. A receiver on the sender chain itself
   reverts (`GovReceiverLocalEmitter`).
3. Requires the VAA sequence to be at least `nextMinimumSequence` and advances
   the counter to `sequence + 1` — before anything executes, so a delivered VAA
   can never be re-executed. This is the replay protection, taken from the
   audited Uniswap receiver: it is a single monotonically increasing counter,
   nothing more.
4. Expiry: a VAA older than `_MESSAGE_TIMEOUT` (`2 days`, measured from the
   guardians' timestamp) reverts (`GovReceiverMessageExpired`) **without**
   advancing the counter, so it can be re-delivered after the failure condition
   is fixed. Because gaps are allowed (step 3), a permanently expired message
   can also simply be leapfrogged by any later sequence — expiry can never clog
   the pipeline. Recovery is a re-send from the sender chain, which carries a
   fresh timestamp.
5. Decodes `CrossChainPayload` and verifies `targetWormholeChainId` equals the
   local chain, then executes the `actions` batch in order via
   `GovernanceActionLib.execute`, the same internal call primitive used by local
   proposal execution: any sub-call failure reverts the whole delivery with the
   target's revert payload, and the sequence advance rolls back with it. The
   action has been approved by the sender chain's governance and is expected to
   succeed; a failure means a precondition was missed and is surfaced loudly,
   not silently skipped. The same VAA remains deliverable once the precondition
   is fixed.

If the governance strategy has no Wormhole address configured,
`receiveMessage` reverts with `GovReceiverNotConfigured`: the chain has not
opted in as a receiver.

### Ordered execution and replay protection

Wormhole assigns an increasing sequence number (starting at 0) to every message
published by a given emitter. The receiver stores a single counter,
`nextMinimumSequence`, and requires each VAA to carry a sequence at least that
high (`GovReceiverInvalidSequence` otherwise), then advances the counter to
`sequence + 1`:

- The counter advances **before** the batch executes, so a delivered VAA can
  never be re-executed: re-delivering it fails the sequence check, since its
  sequence is now strictly below the minimum. A re-send is a _new_ publication
  with a new sequence and therefore requires a fresh governance-approved
  execution on the sender chain — it is not a replay of the old VAA.
  `test_ReceiveMessage_ReplayedVaa_Reverts` covers the replay attempt and
  `test_ReceiveMessage_ResentAction_ExecutesAsNewMessage` covers the legitimate
  counterpart. The fork test re-delivers an executed VAA against the real
  Wormhole core to prove the sequence check is reachable and rejects the batch
  before any re-execution.
- **Gaps are allowed**: a message with a higher sequence advances the minimum
  past any missing sequence, so a lost or permanently failing message can never
  clog the pipeline — exactly the property of the audited Uniswap receiver.
- A message with a **past** sequence is a replay attempt and reverts.
- An **expired** message (older than `2 days`) reverts without advancing the
  counter; it can be re-delivered after recovery, or leapfrogged by a later
  sequence. An old approved action can never become executable years later.

A single mainnet `execute()` may publish several messages (one per Wormhole action in the
proposal, e.g. one per destination chain). Wormhole assigns each `publishMessage` call the
next consecutive per-emitter sequence. The executor attaches the summed message fees:
`beforeExecute` sets each action's value to a fresh `messageFee()` read and `execute`
requires `msg.value` to equal the total exactly.

**Ordering guarantees.** Sequences are consecutive by construction (the Wormhole core
contract assigns them at `publishMessage` time, and a cancelled or defeated proposal never
publishes). In-order delivery therefore executes governance actions in the exact order
they were approved, which matters because batches are authored with dependencies in mind
(e.g. upgrade a strategy, then call it). Actions within one message execute atomically in
their encoded order. Across messages, the receiver enforces increasing accepted sequence
numbers, not delivery of every earlier message: a successful later delivery permanently
invalidates any earlier undelivered VAA on that receiver (its sequence falls below
`nextMinimumSequence`). An inverted delivery therefore costs one reverted relay
transaction only when the earlier message is delivered again before any later one lands;
otherwise the inversion is permanent — the later message's effects apply and the earlier
message requires fresh governance-approved publication, after rechecking its
preconditions, to take effect at all. Batch dependent same-target actions into one
message. An orphaned action does not self-heal by retrying the old VAA.

Each message carries a batch of `ProposedAction`s, executed on the destination chain one by
one in the encoded order via `GovernanceActionLib.execute` — the same pre-audited assembly
call primitive local `execute` uses — so a coupled upgrade (adapter + implementation)
lands atomically in one message. Self-targeted actions (the governance proxy itself) go
through the same `onlyGovernance` path as locally executed proposals: the receiver can
upgrade its own implementation, strategy, and voting thresholds;
`test_ReceiveMessage_BatchWithSelfUpgrades_Executes` and
`test_ReceiveMessage_UpgradesThresholds_ViaSelfCall` assert this.

This is deliberately the minimal model: a single storage slot (the sequence
counter), the exact validation order of the audited Uniswap receiver, and revert-
on-failure execution. No hash registry, no per-message consumed flags, no
sender-side application nonce, no owner-gated resync hatch — every additional
counter or registry is another thing that can drift or clog, and none is needed:
Wormhole's per-emitter sequence alone provides ordering and replay protection.

### Failed actions: revert, fix, re-deliver

A target action that reverts reverts the whole delivery, and the sequence
advance rolls back with it:

- The failure is surfaced loudly with the target's revert payload (the same
  semantics as a locally executed proposal, which also reverts on failure), so a
  missed precondition is diagnosable instead of silently skipped.
- The message is **not** consumed: the same VAA remains deliverable once the
  precondition on the target chain is satisfied, as long as it has not expired
  and no later message has been delivered in the meantime (a later delivery
  advances the minimum past it permanently)
  (`test_ReceiveMessage_FailedAction_RecoveredByRedelivery`), and any later
  sequence can leapfrog it in the meantime
  (`test_ReceiveMessage_FailureDoesNotBlockNextMessage`). An expired VAA needs
  fresh publication, not simply a repaired action precondition.
- Action preconditions should be checked on the sender chain where possible (the
  strategy's `beforePropose` does this for payload shape and value), so that a
  message is only sent when it is expected to execute.
- Recovery of a permanently unwanted action is the sender chain governance
  re-sending the corrected action in a new message, or doing nothing: gaps are
  allowed, so an abandoned sequence never stalls anything.

### Model: the audited Uniswap receiver, adapted

The receiver follows the [audited `UniswapWormholeMessageReceiver`](https://github.com/Uniswap/governance-crosschain-bridges/blob/master/src/WormholeMessageReceiver.sol)
as closely as the architecture allows:

- `sequence >= nextMinimumSequence`, then `nextMinimumSequence = sequence + 1`:
  gaps are allowed, so a lost, expired, or permanently failing message can never
  clog the pipeline. Their own code warns that mixed consistency levels can
  orphan a slow message behind a fast later one — we pin the consistency level
  in the payload validation, same mitigation.
- `MESSAGE_TIME_OUT_SECONDS` (2 days): a VAA older than the timeout reverts
  instead of executing, so an accidentally skipped action can never become
  executable years later. Unlike Uniswap — whose timeout is only sound _because_
  gaps are allowed and expiry reverts the delivery — we need no special
  expire-and-advance logic: the gap allowance already guarantees expiry cannot
  clog anything.
- Sub-call failure reverts the whole delivery and the sequence advance rolls
  back: the same VAA stays redeliverable after recovery, and any later sequence
  can leapfrog it. No skip-and-report, no failure registry.

The differences from the Uniswap receiver are driven by our architecture, not by
a different security model:

- **Batched payload.** Uniswap publishes `(version, targets, values, calldatas,
receiver, chainId)` and executes the sub-calls directly. We publish a single
  `CrossChainPayload { targetWormholeChainId, proposalId, actions }` where
  `actions` is a batch of `ProposedAction`s executed atomically in order via the
  same `GovernanceActionLib.execute` primitive local proposals use — so a coupled
  upgrade (adapter + implementation) lands in one message, and self-targeted
  actions (implementation/strategy/threshold upgrades) go through the same
  `onlyGovernance` path as locally executed proposals.
- **Emitter identity.** Uniswap stores the sender address as an immutable; we
  assert `emitterAddress == address(this)` because the governance proxy is
  deployed at the same deterministic address on every chain — no per-chain
  emitter configuration and the receiver address is known in advance.
- **Value policy.** Uniswap's receiver forwards `msg.value` to sub-calls; our
  payloads are message-only (every inner action `value == 0`, validated on the
  sender chain at proposal time), so the receiver never handles value and the
  relayer needs no funds.
- **No application-level nonce.** The newer [modular-multichain-governance](https://github.com/Uniswap/modular-multichain-governance)
  adds a payload nonce tracked on the sender (`WormholeEncoder.nonces`) with
  strict equality on the receiver plus an owner-gated `emergencySetNonce` hatch.
  That counter exists because the module architecture abstracts the bridge: the
  Wormhole sequence stays in the VAA envelope and never enters the generic
  payload. We use Wormhole's per-emitter sequence directly, so sender and
  receiver can never drift apart and no privileged resync hatch is needed.

## Recovery

Because the receiver is part of the governance implementation, recovery uses the
governance's own existing mechanisms, with no separate owner or admin key:

- The chain's **local governance** can propose and execute `upgradeImplementation`
  or `upgradeStrategy` (both `onlyGovernance`), replacing the receiver logic or
  reconfiguring the Wormhole address — upgrading the strategy takes effect
  immediately, since the Wormhole address is read from it on every delivery.
  On receiver chains the local governance acts through its own staking-based
  voting; it does not depend on Wormhole.
- A **compromised Wormhole guardian set** (forged VAAs) is countered the same
  way: a local strategy upgrade pointing `wormhole()` at the zero address
  disables the receiver instantly (`GovReceiverNotConfigured`), and a follow-up
  upgrade can swap in a receiver for a different bridge. No externally owned
  account is involved in either step.
- A permanently **failing action** is never fatal: the delivery reverts without
  consuming the message, so the same VAA can be re-delivered after recovery, or
  simply abandoned — gaps are allowed and a later sequence leapfrogs it.
- Mainnet governance keeps full control of the sender side through ordinary
  proposals.

The single **catastrophic scenario** — the only one with no trustless recourse — is
Wormhole itself being down: if the guardian network cannot produce or verify VAAs, no
cross-chain message can be delivered and the receiver stalls (already-approved actions
simply wait; nothing executes out of order or twice). This is intended behavior. The
escape hatch does not depend on Wormhole: each receiver chain's local governance can
upgrade its strategy or implementation through an ordinary local proposal, so the
governances retain full control of their own chains even in a permanent Wormhole outage.

Day-to-day execution remains trustless: only messages verified against the
trusted mainnet emitter are executed, and neither the local governance voters
nor any third party can forge a VAA.

## Receiver is part of governance, not the protocol

The receiver logic lives in `contracts/governance/mixins/MixinCrosschain.sol`
and its interface in `contracts/governance/interfaces/governance/IGovernanceCrosschain.sol`.
Executing a cross-chain action through the governance proxy means the action
runs with the governance proxy's authority on that chain — the same trust
relationship as a locally executed proposal, just authorized by the sender
chain's governance instead of the local one.

## Why the governance proxy is the receiver

Making the governance proxy the receiver hub (instead of a dedicated contract)
is deliberate:

- The governance proxy already exists on every chain at a deterministic,
  well-known address, so no extra deployment or proxy is needed and the
  receiver address is known in advance on new chains.
- The receiver benefits from the governance proxy's existing upgrade path:
  receiver fixes ship inside governance implementation upgrades.
- The receiver state is a single dedicated storage slot, completely separate
  from voting state, and asserted in the `MixinStorage` constructor like every
  other governance slot.

The trade-off — the receive path shares the governance implementation's audit
surface — is accepted because the validation sequence is identical to the
Wormhole reference receiver, and the sender chain is fixed to Ethereum mainnet
by the strategy.

**Re-entrancy.** Actions execute as arbitrary calls from the governance, with no
reentrancy lock (matching the Uniswap reference receiver). The sequence number is
bumped *before* execution, so an action that re-delivers its own VAA reverts
(`GovReceiverInvalidSequence`) and the whole batch rolls back — same-VAA re-entrancy
is impossible. An action that delivers a *different, later* VAA mid-execution would
nest a second batch; this is accepted because every delivered VAA still passes the
full emitter/chain/sequence/expiry validation, so nesting grants no extra authority
beyond what a valid later message already has.

## Quorum snapshot (issue #200)

When a proposal is created, the current `quorumThreshold` is copied into a
separate `proposalQuorumById` mapping. All subsequent state checks for that
proposal use the snapshotted value. If the quorum is later changed by another
successful proposal, the state of past proposals remains deterministic.

Proposals created before this feature was introduced do not have a snapshot;
their mapping entry is `0`. `_getProposalState` treats those legacy proposals as
if their quorum were `type(uint256).max`, so they can never reach quorum and
can never be executed. This closes [#200][issue-200] for legacy proposals as
well: a later reduction of the global quorum cannot resurrect a past failed
proposal. New proposals created after the upgrade snapshot the quorum at creation
time and are unaffected by later quorum changes.

The snapshot is stored in a dedicated mapping rather than appended to the
`Proposal` struct. This keeps the `Proposal` storage layout and ABI unchanged,
so existing strategies and external clients remain compatible. The snapshotted
quorum is an internal implementation detail; external callers receive the
effective quorum through `getProposalState(proposalId)`.

## Deployment

`src/deploy/deploy_governance.ts` deploys the same suite on every chain:
`RigoblockGovernanceFactory` (no constructor arguments), `RigoblockGovernance`
(no constructor arguments — same address on every chain), then
`RigoblockGovernanceStrategy` with the chain's staking proxy and Wormhole
configuration. A chain with a nonzero Wormhole address in
`src/utils/constants.ts` is a receiver chain; a chain with a zero Wormhole
address is not able to process cross-chain messages.

Chain-specific Wormhole addresses and chain ids are stored in
`src/utils/constants.ts` and `contracts/test/Constants.sol`.

## Testing

- Foundry (cross-chain receiver inside the governance implementation, including
  replay protection, gap tolerance, expiry, failure recovery by redelivery, and
  local governance coexisting with receiving):
  `forge test --match-path test/governance/Governance.Crosschain.t.sol`
- Foundry mainnet fork (multi-message batch against the real Wormhole core contract:
  real `publishMessage`, real consecutive sequence assignment, real `messageFee`; only
  guardian signature verification is mocked):
  `forge test --match-path test/governance/Governance.CrosschainFork.t.sol`
- Foundry (strategy Wormhole validation):
  `forge test --match-path test/governance/RigoblockGovernanceStrategy.t.sol`
- Foundry (local migration simulation):
  `forge test --match-path test/governance/GovernanceMigration.t.sol`
- Foundry (mainnet-fork migration simulation):
  `forge test --match-path test/governance/GovernanceMigrationFork.t.sol`
- Hardhat (full staking, voting and execution flow):
  `npx hardhat test mocha test/governance/Governance.spec.ts --network hardhat`

The Hardhat tests are kept because they exercise the full staking, voting, and
execution flow that the Foundry unit tests mock.

[issue-200]: https://github.com/RigoBlock/v3-contracts/issues/200
