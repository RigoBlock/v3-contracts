# 🔐 Security Review — RigoblockGovernance

---

## Scope

|  |  |
| --- | --- |
| **Mode** | filename |
| **Files reviewed** | `RigoblockGovernance.sol` · `MixinVoting.sol` · `MixinState.sol`<br>`MixinCrosschain.sol` · `MixinUpgrade.sol` · `MixinStorage.sol`<br>`MixinInitializer.sol` · `MixinConstants.sol` · `MixinImmutables.sol`<br>`MixinAbstract.sol` · `GovernanceActionLib.sol` |
| **Confidence threshold (1-100)** | 75 |

Audited at commit ref `development` of `RigoBlock/v3-contracts`. Both strategies (`RigoblockGovernanceStrategy`, `WormholeReceiverStrategy`), the governance interfaces and types, and the OpenZeppelin Governor integration surface were read as context for reachability; they are not in scope. The strategies were audited separately on `fix/gov-crosschain-strategy`.

---

## Findings

_None — this scan raised no findings._

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **The qualified denominator is snapshotted on the first vote, not at proposal creation** — `MixinVoting._countVote` — Code smells: the `extraData.votingPower` slot doubles as a set-once flag; the snapshot waits for the first voter; the voting window can straddle a staking-epoch roll — A window that crosses an epoch roll lets the first vote fix the qualified-majority denominator from the later epoch, and stake moved between accounts at the roll can be counted twice on the same proposal. Same root cause as the split-epoch-window lead in the `RigoblockGovernanceStrategy` report; the seam sits here in the mixin. We did not measure how far delegation can move between two epochs.
- **The ERC-6372 clock is hardcoded to timestamps while a block-number mode exists** — `MixinState.clock` — Code smells: `CLOCK_MODE()` and `clock()` ignore `governanceParameters.timeType`; `TimeType.Blocknumber` is an accepted deployment parameter — A block-number deployment would expose block-number snapshots and deadlines next to a timestamp clock, so Governor integrations such as Tally would misreport every voting window. On-chain voting uses the native state path and is unaffected. Both current strategies require `TimeType.Timestamp`, so no affected deployment can exist today.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
