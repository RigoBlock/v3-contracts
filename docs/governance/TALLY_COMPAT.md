# Tally / OpenZeppelin Governor Compatibility

Rigoblock governance can be indexed and operated through [Tally](https://www.tally.xyz)
because it directly inherits OpenZeppelin's `IGovernor`, `EIP712` and `Nonces` from a
dedicated vendored submodule (`lib/openzeppelin-gov`, v5.7.0, remapping
`@openzeppelin-gov/`). There is no separate compatibility interface: the OZ function
signatures, selectors, events, enums and signature-validation logic are the governance's
own surface, implemented by the mixins (`MixinState` views, `MixinVoting` propose/vote/
execute paths, `MixinUpgrade` parameter events). Interface compatibility is
compile-enforced by `override` against the vendored OZ sources.

## Supported surface

### ERC-6372 clock

- `clock()` returns `uint48(block.timestamp)`.
- `CLOCK_MODE()` returns `"mode=timestamp"`.

Rigoblock governance is timestamp-based (`TimeType.Timestamp`); block-number-based
governances are rejected by the Rigoblock strategy (see `docs/governance/STRATEGY.md`).

### Proposal state

`state(uint256)` is the OZ view and returns the OZ `ProposalState` enum. The native
enum is `ProposalStatus`, declared in `contracts/governance/types/GovernanceTypes.sol`
and **imported** (not inherited) by `IGovernanceState`: an import does not inject the
name into inheriting contracts, so the two same-meaning enums coexist unambiguously
(`ProposalStatus` = Rigoblock native, `ProposalState` = OZ). Its historical numbering
is ABI- and storage-neutral, and `state()` translates on read:

| OZ value | OZ state  | Rigoblock native value | Rigoblock state |
| -------: | --------- | ---------------------: | --------------- |
|        0 | Pending   |                      0 | Pending         |
|        1 | Active    |                      1 | Active          |
|        2 | Canceled  |                      2 | Canceled        |
|        4 | Succeeded |                      3 | Qualified       |
|        3 | Defeated  |                      4 | Defeated        |
|        4 | Succeeded |                      5 | Succeeded       |
|        5 | Queued    |                      6 | Queued (unused) |
|        6 | Expired   |                      7 | Expired         |
|        7 | Executed  |                      8 | Executed        |

Rules: native values up to `Canceled` (2) are identical; native `Qualified` (3) maps to
OZ `Succeeded` (4) because a Qualified proposal is already approved (executable from the
next block/timestamp); all higher native values shift down by one.

This is safe for existing governances: proposal state is computed on demand and never
stored, so the translation applies uniformly to past and future proposals with no
migration step. The native `getProposalState(uint256)` keeps the historical numbering.

### Voting

- `castVote(uint256, uint8)`, `castVoteWithReason(uint256, uint8, string)` and
  `castVoteWithReasonAndParams(uint256, uint8, string, bytes)` implement the exact OZ
  signatures (`uint8 support`). Solidity does not allow an enum parameter to override a
  `uint8` parameter (both encode externally as `(uint256, uint8)` and clash), so the OZ
  `uint8` form is the single implementation; the incoming value is converted to the
  internal `VoteType` enum and anything above 2 reverts with `GovInvalidSupport(uint8)`.
- The native `VoteType` enum is ordered to match the OZ support values:
  **0 = Against, 1 = For, 2 = Abstain**, so a Tally vote encodes identically to a
  native call — asserted in `test/governance/Governance.TallyCompat.t.sol` against the
  vendored OZ `IGovernor`.
- Votes emit both the native `VoteCast(voter, proposalId, voteType, votingPower)` and
  the OZ `VoteCast(voter, proposalId, support, weight, reason)` events so existing
  integrations keep working while Tally indexes the OZ format.
- `hasVoted(uint256, address)`, `proposalVotes(uint256) → (against, for, abstain)` and
  `COUNTING_MODE() == "support=bravo&quorum=bravo"` expose receipts and tallies in OZ
  shape.

### Signed voting (OZ Governor ballot)

`castVoteBySig(uint256, uint8, address, bytes)` and
`castVoteWithReasonAndParamsBySig(...)` follow the OZ Governor exactly, including
ERC-1271 contract-signature support via `SignatureChecker.isValidSignatureNow`:

- The EIP-712 domain is inherited from OZ's `EIP712` with a **fixed** domain name
  (`"Rigoblock Governance"`, constant `_EIP712_NAME`) and the implementation `VERSION`
  as domain version. OZ's `EIP712` binds name/version as constructor immutables (in every
  5.x release), so the per-governance storage name cannot be used in the domain.
- The struct is the OZ `Ballot(uint256 proposalId,uint8 support,address voter,uint256 nonce)`
  (or `ExtendedBallot(...)` with reason and params); the nonce comes from the inherited
  OZ `Nonces` contract (`nonces(voter)` view) and is consumed by each validation,
  following OZ semantics. Invalid signatures revert with `GovInvalidSignature(voter)`.
- `eip712Domain()` (ERC-5267) is exposed by the inherited `EIP712` for wallet discovery.

### Proposing, queueing and executing

- The OZ overload `propose(address[] targets, uint256[] values, bytes[] calldatas, string description)`
  assembles the actions and routes to the native `propose(ProposedAction[], string)`.
  Mismatched array lengths revert with `GovActionsLengthMismatch()`.
- Proposals emit both the native
  `ProposalCreated(proposer, proposalId, actions, startBlockOrTime, endBlockOrTime, description)`
  and the OZ
  `ProposalCreated(proposalId, proposer, targets, values, signatures, calldatas, startBlock, endBlock, description)`
  events. `signatures` is always empty: Rigoblock actions carry raw calldata.
- Sequential proposal ids are retained. At propose time the OZ hash
  (`hashProposal(targets, values, calldatas, descriptionHash)`) is stored in a dedicated
  ERC-7201 slot mapping it to the proposal id, so the OZ
  `execute(targets, values, calldatas, descriptionHash)` and
  `cancel(targets, values, calldatas, descriptionHash)` resolve to the same stored
  proposal (unknown hashes revert with `GovProposalIdUnknown(bytes32)`). The native
  `execute(uint256)` / `cancel(uint256)` are unchanged for existing integrations.
- There is no timelock: `queue(...)` reverts with `GovQueueNotImplemented(proposalId)`,
  `proposalNeedsQueuing` returns false and `proposalEta` returns 0.
- `supportsInterface` reports `IERC165`, `IGovernor`, `IERC6372` and `IERC5267`
  interface ids.

### Parameters

- `votingDelay()` returns `1` (voting starts at `block.timestamp + 1`); `votingPeriod()`,
  `name()`, `version()` and `proposalThreshold()` are declared once, by OZ's `IGovernor`,
  and implemented in `MixinState`.
- `proposalSnapshot(proposalId)` / `proposalDeadline(proposalId)` return the stored
  start/end timestamps.
- `updateThresholds` emits the OZ `ProposalThresholdSet` event (with the new proposal
  threshold) for Tally indexing. The historical `ThresholdsUpdated` event was removed:
  it was never emitted by any live governance, so nothing off-chain depends on it. There
  is deliberately no quorum event: the OZ base-Governor surface for quorum is the
  `quorum(uint256)` view. `QuorumNumeratorUpdated` belongs to
  `GovernorVotesQuorumFraction`, which implements fraction-of-total-supply quorums —
  Rigoblock uses an absolute threshold, so that event does not apply.
- `ProposalCanceled` / `ProposalExecuted` are emitted under OZ's declarations (the
  duplicates were removed from the native events interface; the event topics are
  identical, so historical indexing is unaffected).

## Approximations and limitations

- `quorum(timepoint)` returns the stored quorum threshold only. Rigoblock additionally
  requires a **2/3 qualified majority of global delegated stake** to reach the Qualified
  state; Tally has no representation for this, so its quorum display is incomplete.
- `getVotes(account, timepoint)` returns the account's **current** voting power.
  Rigoblock voting power is epoch-based and timepoint-specific values cannot be
  reconstructed on chain. `getVotesWithParams` delegates to `getVotes`.
- Tally's governance page reads `quorum`, `proposalThreshold`, and voting power through
  the above views; values labeled with the caveats above are approximations.

## Deployment notes

The OZ surface is compiled into the governance implementation (VERSION 1.3.0). A live
governance gains it by the standard implementation-upgrade flow (factory
`setImplementation` + per-governance `upgradeImplementation` proposal).

Storage note: the inherited OZ `EIP712` and `Nonces` contracts keep a few **regular sequential
storage slots** — OZ does not implement the Rigoblock ERC-7201 namespaced storage pattern
(checked against OZ v5.7.0, identical on `master`). Since VERSION 1.3.0, the implementation
neutralizes this with overrides: `MixinVoting` overrides `nonces` and `_useNonce` so that voter
nonces live in the ERC-7201 slot `keccak256("governance.proxy.voter.nonces") - 1` (asserted
in `MixinStorage`), exactly like every other governance mapping. (`_useCheckedNonce` needs
no override: OZ's implementation writes only through the virtual `_useNonce`, so it
dispatches to the overridden, namespaced version.) All **live** governance state is
therefore namespaced. The
sequential slots are permanently-zero OZ placeholders and are never read or written by
Rigoblock code:

- **slot 0 — OZ `Nonces._nonces`.** Declared `private` in OZ, so inheriting `Nonces` reserves
  the slot in the layout even though the overrides never touch it. Dead placeholder.
- **slots 1–2 — `EIP712._nameFallback` / `_versionFallback`.** OZ marks both "Deprecated.
  Kept to preserve the storage layout of inheriting contracts used as an implementation
  behind a proxy." All EIP-712 domain data lives in immutables; the v5.7 constructor uses
  `toShortString()` (reverts on names longer than 31 bytes) and never writes the fallbacks.
  Dead placeholders, kept so contracts deployed under OZ ≤5.2 — where these slots held real
  strings — can upgrade in place.

It cannot clash with existing governance data, for two reasons:

1. slots 0–2 were **empty** before VERSION 1.3.0: the implementation kept all of its state
   in ERC-7201 namespaced slots (hashed values in a ~2^256 range) and had no regular storage
   at all;
2. ERC-7201 slots and low sequential slots live in disjoint, astronomically distant address
   spaces, so no namespaced slot can ever collide with slots 0–2 — and no future regular
   storage may be added to the implementation without first auditing these three slots.

Any future upgrade must preserve this layout: `EIP712` and `Nonces` stay in the inheritance
chain (so the placeholder slots keep their positions), and no new regular-storage base may be
inserted before them. Because no live state sits in sequential slots, a future OZ release
migrating `Nonces`/`EIP712` to namespaced storage cannot silently reset any Rigoblock state.

Votes cast through the `AGovernance` pool adapter follow the adapter's own semantics:
see the adapter's integration notes in
`docs/api/protocol/extensions/adapters/AGovernance.md`.

## VoteType reordering and historical display

Pre-upgrade implementations declared `VoteType { For, Against, Abstain }` (For = 0). The
enum is reordered to `VoteType { Against, For, Abstain }` so it matches the OZ support
ordering. This is execution-safe: no on-chain logic reads a stored `Receipt.voteType`
(tallies are separate counters), so no past proposal outcome can change. What inverts is
**historical display**:

- receipts and the native `VoteCast` event of pre-upgrade proposals were written with
  the old ordering — a historical `VoteType.For` (0) now decodes as `Against` through
  the new interface (and vice versa). Off-chain indexers must pin the enum ordering to
  the implementation version that wrote the data;
- voting is only possible while a proposal is Active, so a proposal voted on after the
  upgrade records its receipt under the new ordering and displays correctly. The only
  inverted data is what was written before the upgrade.

Signed votes moved from the legacy `Vote(uint256 proposalId,uint8 support)` typehash to
the OZ Governor `Ballot(uint256 proposalId,uint8 support,address voter,uint256 nonce)`
typehash with a fixed domain name ("Rigoblock Governance") and the implementation
version as domain version. Previously collected signatures are invalidated by this
change by design. Integrators that hardcoded support values must switch to the new
ordering (For is now 1).
