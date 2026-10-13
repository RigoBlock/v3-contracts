# 🔐 Security Review — RigoblockGovernanceStrategy

---

## Scope

|  |  |
| --- | --- |
| **Mode** | filename |
| **Files reviewed** | `RigoblockGovernanceStrategy.sol` |
| **Confidence threshold (1-100)** | 75 |

Audited at commit ref `fix/gov-crosschain-strategy` of `RigoBlock/v3-contracts`. The governance mixins (`MixinVoting`, `MixinState`, `MixinCrosschain`, `MixinUpgrade`), the staking contracts (`MixinScheduler`, `MixinFinalizer`, `MixinStakeBalances`, `MixinStakeStorage`), `GovernanceActionLib` and the factory were read as context for reachability; they are not in scope.

---

## Findings

_None — this scan raised no findings._

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **A delayed epoch roll splits the voting window across two epochs** — `RigoblockGovernanceStrategy.beforePropose` — Code smells: the window anchors to the epoch's earliest end; the roll waits for any caller; the first vote snapshots the qualified denominator from its own epoch — The first vote before the roll stores the old epoch's total as the qualified denominator, and later votes use new-epoch balances. We did not measure how far delegation can move between two epochs.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
