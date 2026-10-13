# 🔐 Security Review — WormholeReceiverStrategy

---

## Scope

|  |  |
| --- | --- |
| **Mode** | filename |
| **Files reviewed** | `WormholeReceiverStrategy.sol` |
| **Confidence threshold (1-100)** | 75 |

Audited at commit ref `fix/gov-crosschain-strategy` of `RigoBlock/v3-contracts`. The governance mixins (`MixinVoting`, `MixinState`, `MixinCrosschain`), `GovernanceActionLib`, the sender strategy and the factory were read as context for reachability; they are not in scope.

---

## Findings

_None — this scan raised no findings._

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Any proposal threshold passes strategy validation** — `WormholeReceiverStrategy.validateParams` — Code smells: validateParams accepts any value; the propose gate is `>=`; getVotingPower caps at type(uint96).max — A zero threshold lets any caller propose during an active recovery; a threshold above uint96.max bricks the recovery path itself. We did not confirm which threshold the production factory sets.
- **The strategy cannot verify the governance proxy address** — `WormholeReceiverStrategy.constructor` — Code smells: nonzero-only check on `_governanceProxy`; immutable written once; the veto path has no on-chain probe — The constructor probes the wormhole address but only checks the governance proxy for nonzero. A wrong address silently disables the veto, and an active recovery then runs unopposed; we did not check how deployments compute it.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
