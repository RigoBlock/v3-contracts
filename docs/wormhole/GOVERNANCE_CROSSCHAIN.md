# Wormhole Cross-Chain Governance

This document describes how Rigoblock governance on Ethereum mainnet controls
target chains such as HyperEVM through Wormhole cross-chain messages.

## Goals

- No governance proxy on the target chain.
- No staking rewards / staking proxy on the target chain.
- Any governance proposal can include actions that target the local Wormhole core contract.
- Each target-chain receiver is configured to trust a specific emitter (by default the Ethereum mainnet governance proxy), so only messages from that emitter are executed.
- Actions are executed on the target chain in the exact order they were sent.
- Each proposal is protected against replay on every chain.
- Proposal quorum is snapshotted at creation time so future quorum changes cannot
  alter the outcome of an existing proposal (fixes [#200][issue-200]).

## Architecture

```
Ethereum mainnet
  RigoblockGovernance proxy
    └─ MixinVoting.execute
       └─ every action is routed through RigoblockGovernanceStrategy.beforeExecute
       └─ Wormhole actions call IWormhole.publishMessage{value: messageFee}(payload)

Target chain (e.g. HyperEVM)
  CrosschainReceiverProxy  (owner: Rigoblock recovery wallet)
    └─ CrosschainReceiver (implementation, upgradeable by owner)
       └─ parseAndVerifyVM(encodedVaa)
          └─ execute actions in order
```

The `RigoblockGovernance` implementation has no constructor arguments, so it can
be deployed at the same deterministic address on every chain. The Wormhole core
address is stored in `RigoblockGovernanceStrategy`, which is deployed per chain
and therefore does not affect the governance implementation address.

Each target-chain `CrosschainReceiver` is configured with the Wormhole-formatted
address of the trusted emitter (by default the Ethereum mainnet governance proxy
`0x5F8607739c2D2d0b57a4292868C368AB1809767a`) and the Wormhole chain id of
Ethereum (`2`).

## Governance side

A cross-chain proposal is an ordinary governance proposal. Each cross-chain
action is a normal `ProposedAction`:

- `target` = the local Wormhole core contract.
- `data` = `abi.encodeCall(IWormhole.publishMessage, (nonce, encodedPayload, consistencyLevel))`.
- `value` = `0` at proposal time. The Wormhole fee is not part of the proposal;
  it is attached by the strategy at execution time (see below).

The `encodedPayload` is `abi.encode(CrossChainPayload)`:

- `targetWormholeChainId`: the destination Wormhole chain id. The receiver
  asserts this matches the local chain, so a VAA intended for another chain
  cannot be replayed here.
- `proposalId`: the mainnet proposal id that produced the message. It is
  included for auditability and off-chain indexing; replay protection is
  enforced by the Wormhole VAA hash and by atomic proposal execution on
  mainnet.
- `action`: the single `ProposedAction` to execute on the target chain. Its
  `value` is paid on the destination chain from the receiver contract's own
  balance — it is not sent through Wormhole and must not be confused with the
  source-chain fee. If the receiver holds insufficient native currency for the
  inner action value, execution fails and the action is deferred to
  `failedActions` (see Receiver side), from where it can be retried once the
  balance is funded.

Because cross-chain messages are ordinary proposal actions, the existing
`PROPOSAL_MAX_OPERATIONS` limit is respected and each action is validated
individually by the strategy.

`RigoblockGovernanceStrategy` enforces, via `beforePropose` / `beforeExecute`:

- Cross-chain actions are only allowed on Ethereum mainnet (`block.chainid == 1`).
- If `action.target == wormhole`, the calldata selector must be
  `IWormhole.publishMessage.selector` and the decoded `CrossChainPayload` must
  target a chain other than the local Wormhole chain id.
- The wrapper `value` must be `0` at proposal time (`GovCrosschainInvalidValue`
  otherwise), because the inner action value is a destination-chain concern.
- At execution time, `beforeExecute` sets `action.value = messageFee()`.
  Wormhole's `publishMessage` requires `msg.value == messageFee()` exactly, so
  the fee is read fresh at execution and any proposer-supplied value would be
  overridden — this avoids estimating the fee client-side and risking a
  transaction that reverts because the fee changed.

## Receiver side

`CrosschainReceiver` is deployed behind a `CrosschainReceiverProxy` on each
target chain (the proxy is the address governance actions target). It follows
the same validation steps as the Wormhole `HelloWorld` example:

1. Parses and verifies the VAA through the Wormhole core contract.
   `parseAndVerifyVM` checks the guardian-set signature proof. Forged or
   malformed VAAs return `valid == false` and the receiver reverts with the
   reason provided by Wormhole.
2. Asserts the emitter chain id and emitter address match the trusted mainnet
   governance proxy.
3. Checks the `consumed` mapping to prevent replay of a valid VAA.
4. Verifies the payload's `targetWormholeChainId` equals the local chain.

The VAA is marked `consumed` only after emitter and target-chain checks pass.
This prevents a VAA intended for a different chain from being burned here.

The receiver then uses Wormhole's per-emitter `sequence` to enforce ordered
execution:

- If `sequence == expectedSequence`, execute immediately.
- If `sequence > expectedSequence`, queue the payload until its predecessors
  arrive. The VAA is already marked `consumed`, so it cannot be processed twice.
- If `sequence < expectedSequence`, revert (`GovReceiverSequenceTooOld`).

After executing a message, the receiver processes any queued messages that are
now ready, at most 8 per call (`_MAX_QUEUE_DRAIN`). The remainder stays queued
and drains lazily on subsequent deliveries, bounding the gas a single
`receiveMessage` call can spend.

## Failed actions: skip, defer, retry

A target action that reverts does **not** revert the delivery that carried it
and does **not** block the pipeline (a synchronously reverting queue entry
would otherwise roll back an otherwise valid delivery and permanently jam every
later message, since the queue is re-drained on each delivery):

- The failing action is stored in `failedActions[sequence]`, a
  `CrossChainActionFailed` event is emitted, and `expectedSequence` advances
  past it. `receiveMessage` therefore always succeeds once the VAA itself is
  valid, for both the direct path and the queue drain.
- Anyone can call `retryFailedAction(sequence)` once the action's
  preconditions on the target chain are satisfied. On success the entry is
  cleared and `CrossChainActionExecuted` is emitted; a retry that still reverts
  propagates `GovReceiverExecutionFailed`.
- Ordering caveat: a retried action executes after whatever was delivered in
  the meantime. Governance actions should be authored to be
  precondition-safe (target contracts should no-op rather than revert where
  possible). If strict ordering with later actions matters, governance
  re-sends the action as a new message instead of relying on retry.

## Recovery: proxy owner

The receiver is deployed behind a `CrosschainReceiverProxy` whose owner is a
Rigoblock-controlled recovery wallet on the target chain (`governanceOwner` in
`src/utils/constants.ts`). The owner can upgrade the receiver implementation
via `upgradeToAndCall`. This is the same escape hatch Uniswap's
`ReceiverHub` provides through its owner-swappable decoder modules: it covers
Wormhole liveness outages (an implementation can add an alternative message
path), an action that can never succeed, and receiver bugs. Day-to-day
execution remains trustless: only messages verified against the trusted
mainnet emitter are executed, and the owner cannot forge a VAA.

## Ordered execution

Wormhole assigns an increasing sequence number to every message published by a
given emitter. `CrosschainReceiver` starts at `expectedSequence = 1` and only
accepts the next sequence in order. If Wormhole delivers messages out of order,
later messages are stored in `queuedPayloads` and executed automatically when the
missing sequence arrives.

## Replay protection

The Wormhole VAA hash is marked `consumed` as soon as it passes emitter and
target-chain validation. A valid VAA can therefore be submitted by anyone but
executed at most once per receiver. The same VAA cannot be replayed on the
wrong chain because the receiver only accepts messages whose payload specifies
the local Wormhole chain id.

On Ethereum mainnet, the proposal itself can only be executed once because the
`Proposal.executed` flag is set atomically. This prevents a mainnet proposal
from being replayed to emit different cross-chain messages.

## Receiver is part of governance, not the protocol

`CrosschainReceiver` lives under `contracts/governance/crosschain/`. It has no
special authority over Rigoblock pools; it only holds the trust relationship
with the Ethereum mainnet governance proxy and dispatches the decoded actions.

## Why not make the governance contract the receiver?

The governance contract itself could theoretically receive cross-chain messages
on target chains, but a separate `CrosschainReceiver` is preferred:

- It keeps the governance contract's execution surface minimal: on Ethereum
  mainnet the receive path must revert, while on target chains it would need a
  second, privileged execution path. A dedicated receiver isolates that path.
- It avoids bypassing the local strategy on target chains for actions that
  originate from mainnet. The receiver only executes mainnet-authorized actions;
  it does not participate in local voting.
- Deployment and upgrade management are simpler: the receiver is a small,
  single-purpose contract behind an owner-administered proxy, so upgrades and
  redeployments never touch the governance implementation.

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

`src/deploy/deploy_governance.ts` handles chain-specific deployment:

- On receiver chains (any chain with Wormhole config other than mainnet) it
  deploys the `CrosschainReceiver` implementation plus the
  `CrosschainReceiverProxy` pointed at it, with `governanceOwner` from
  `src/utils/constants.ts` as the proxy owner (constructor input, mirroring
  Uniswap's deployer-as-owner except the deployer EOA is never granted
  ownership). The proxy address is the one governance targets on that chain.
  The script throws if `governanceOwner` is unset.
- On all other chains it deploys `RigoblockGovernance` (no constructor
  arguments), then `RigoblockGovernanceStrategy` with the local Wormhole core
  address (or `address(0)` where Wormhole is not available).

Chain-specific Wormhole addresses and chain ids are stored in
`src/utils/constants.ts` and `contracts/test/Constants.sol`.

## Testing

- Foundry (cross-chain receiver + Wormhole integration):
  `forge test --match-path test/governance/CrosschainReceiver.t.sol`
- Foundry (strategy Wormhole validation):
  `forge test --match-path test/governance/RigoblockGovernanceStrategy.t.sol`
- Foundry (quorum snapshot storage layout / backwards compatibility):
  `forge test --match-path test/governance/GovernanceQuorumSnapshot.t.sol`
- Foundry (local migration simulation):
  `forge test --match-path test/governance/GovernanceMigration.t.sol`
- Foundry (mainnet-fork migration simulation):
  `forge test --match-path test/governance/GovernanceMigrationFork.t.sol`
- Hardhat (RIGO-200 end-to-end regression with real staking flow):
  `npx hardhat test test/governance/Governance.Proxy.spec.ts --network hardhat`

The Hardhat regression test is kept because it exercises the full staking,
voting, and execution flow that the Foundry unit tests mock. It proves that a
new proposal's snapshotted quorum survives a later global-quorum reduction.

[issue-200]: https://github.com/RigoBlock/v3-contracts/issues/200
