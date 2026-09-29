# Tally / OpenZeppelin Governor Compatibility

Rigoblock governance can be indexed and operated through [Tally](https://www.tally.xyz)
because it directly inherits OpenZeppelin's `IGovernor` (vendored via the
`@openzeppelin/` remapping) and `IERC6372`. There is no separate compatibility
interface: the OZ function signatures, selectors, events and enums are the governance's
own surface, implemented by the mixins (`MixinState` views, `MixinVoting` propose/vote/
execute paths, `MixinUpgrade` parameter events). Selector-level compatibility is
compile-enforced by `override` against the vendored OZ interfaces.

## Supported surface

### ERC-6372 clock

- `clock()` returns `uint48(block.timestamp)`.
- `CLOCK_MODE()` returns `"mode=timestamp"`.

Rigoblock governance is timestamp-based (`TimeType.Timestamp`); block-number-based
governances are rejected by the Rigoblock strategy (see `docs/governance/STRATEGY.md`).

### Proposal state

`state(uint256)` is the OZ view and returns the OZ `ProposalState` enum. The native
enum is kept as `ProposalStatus` with its historical numbering (renamed only to avoid
the collision with OZ's enum; value numbering unchanged), and `state()` translates on
read:

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

`Qualified` is Rigoblock-specific. Tally only ever sees it as OZ Succeeded (4), which is
the correct user-facing status for an approved proposal.

This is safe for existing governances: proposal state is computed on demand and never
stored, so the translation applies uniformly to past and future proposals with no
migration step. The native `getProposalState(uint256)` keeps the historical numbering.

### Voting

- `castVote(uint256, uint8)`, `castVoteWithReason(uint256, uint8, string)`,
  `castVoteWithReasonAndParams(uint256, uint8, string, bytes)` and the two
  `...BySig` variants implement the exact OZ signatures (`uint8 support`). Solidity
  does not allow an enum parameter to override a `uint8` parameter (both encode
  externally as `(uint256, uint8)` and clash), so the OZ `uint8` form is the single
  implementation; the incoming value is converted to the internal `VoteType` enum and
  anything above 2 reverts with `GovInvalidSupport(uint8)`.
- The native `VoteType` enum is ordered to match the OZ support values:
  **0 = Against, 1 = For, 2 = Abstain**, so a Tally vote encodes identically to a
  native call — asserted in `test/governance/Governance.TallyCompat.t.sol` against the
  vendored OZ `IGovernor`.
- The typed duplicates (`castVote(..., VoteType)`) were removed from the native
  interfaces: they had the same selectors as the OZ forms, so nothing is lost.
- Votes emit both the native `VoteCast(voter, proposalId, voteType, votingPower)` and
  the OZ `VoteCast(voter, proposalId, support, weight, reason)` events so existing
  integrations keep working while Tally indexes the OZ format.
- `hasVoted(uint256, address)`, `proposalVotes(uint256) → (against, for, abstain)` and
  `COUNTING_MODE() == "support=bravo&quorum=bravo"` expose receipts and tallies in OZ
  shape.

### Proposing and executing

- The OZ overload `propose(address[] targets, uint256[] values, bytes[] calldatas, string description)`
  assembles the actions and routes to the native `propose(ProposedAction[], string)`.
  Mismatched array lengths revert with `GovActionsLengthMismatch()`.
- Proposals emit both the native
  `ProposalCreated(proposer, proposalId, actions, startBlockOrTime, endBlockOrTime, description)`
  and the OZ
  `ProposalCreated(proposalId, proposer, targets, values, signatures, calldatas, startBlock, endBlock, description)`
  events. `signatures` is always empty: Rigoblock actions carry raw calldata.
- Sequential proposal ids are retained. At propose time the OZ hash
  (`keccak256(abi.encode(targets, values, calldatas, descriptionHash))`, the canonical
  `hashProposal` formula) is stored in a dedicated ERC-7201 slot mapping it to the
  proposal id, so the OZ `execute(targets, values, calldatas, descriptionHash)` resolves
  to the same stored proposal (reverts with `GovProposalIdUnknown(bytes32)` if the hash
  is unknown). The native `execute(uint256)` is unchanged for existing integrations.
- `supportsInterface` reports `IERC165`, `IGovernor` and `IERC6372` interface ids.

### Parameters

- `votingDelay()` returns `1` (voting starts at `block.timestamp + 1`); `votingPeriod()`
  and `name()` are declared once, by OZ's `IGovernor`, and implemented in `MixinState`.
- `proposalSnapshot(proposalId)` / `proposalDeadline(proposalId)` return the stored
  start/end timestamps.
- `proposalThreshold()` returns the governance's proposal threshold.
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
- `version()` returns the governance implementation version (same value as
  `governanceParameters().version`).

## Approximations and limitations

- `quorum(timepoint)` returns the stored quorum threshold only. Rigoblock additionally
  requires a **2/3 qualified majority of global delegated stake** to reach the Qualified
  state; Tally has no representation for this, so its quorum display is incomplete.
- `getVotes(account, timepoint)` returns the account's **current** voting power.
  Rigoblock voting power is epoch-based and timepoint-specific values cannot be
  reconstructed on chain. `getVotesWithParams` delegates to `getVotes`.
- There is no timelock: `queue` / `execute` (OZ timelock flow) are not implemented and
  are not planned. Execution is direct once a proposal is Succeeded.
- Tally's governance page reads `quorum`, `proposalThreshold`, and voting power through
  the above views; values labeled with the caveats above are approximations.

## Deployment notes

The OZ surface is compiled into the governance implementation (VERSION 1.2.0, which adds
the OZ-hash→proposal-id storage slot). A live governance gains it by the standard
implementation-upgrade flow (factory `setImplementation` + per-governance
`upgradeImplementation` proposal).

The `AGovernance` adapter takes a raw `uint8 support` and passes it verbatim to the
governance — it performs no enum translation, so its behavior is correct under both the
pre-upgrade (`For = 0`) and post-upgrade (`For = 1`) orderings; the interpretation is
always the governance implementation's own `VoteType` ordering at execution time. The
selector is unchanged (`uint8` and enum encode identically), so no Authority
re-registration is needed.

### Migration window (adapters before governance)

The realistic upgrade sequence upgrades the protocol contracts and adapters first, and
the governance's own implementation last (as one of its own proposals). During that
window the new adapter faces the old governance, which still interprets `0 = For`. Since
the adapter passes `support` through unchanged, a caller sending the new (OZ) ordering
(`1 = For`) during the window has its vote recorded as **Against**. Mitigations:

- votes cast _before_ the self-upgrade keep their meaning: tallies are separate counters
  written at cast time and are never re-read through the enum, so pending proposals are
  not corrupted by the flip;
- avoid casting new votes through the adapter for proposals that span the upgrade (cast
  directly against the governance, or wait for the self-upgrade to execute);
- after the self-upgrade, `uint8` values mean exactly what OZ/Tally encode (0 = Against,
  1 = For, 2 = Abstain).

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

The EIP-712 `Vote` struct now follows the OZ typehash
`Vote(uint256 proposalId, uint8 support)` (field renamed from `voteType` to `support`;
domain construction is unchanged — name/version/chainId/verifyingContract). Signature
recovery is delegated to OpenZeppelin's `ECDSA` library (`tryRecover`), replacing the
previous raw `ecrecover` + assert; invalid signatures revert with `GovInvalidSignature()`
(invalid `v`/`s`, malleable `s`, or empty recovery — the cases the old assert swallowed). The
semantics flip applies to signed votes exactly as to direct calls. Integrators that
hardcoded support values must switch to the new ordering (For is now 1); the
`AGovernance` adapter is ordering-agnostic (see the migration window above).
