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
  - **Disposition (addressed in `fix/gov-receiver-init`, by design decision).** On-chain validation is deliberately non-zero-only. The original `code.length` probe made the receiver flow unbootstrappable (the strategy must deploy before the proxy, since the factory's initializer requires a live strategy), and an equality check against a compiled-in address would make the strategy non-generic. Instead, correctness of the configured address is enforced where the deployment happens: `src/deploy/deploy_governance.ts` re-derives the proxy address from the deterministic deployment inputs (`create2(factory, keccak256(abi.encode(creator, name)), proxyInitCode)`) and reverts unless the recorded `governanceProxy` matches, and additionally verifies the deployed strategy bytecode contains the address; `Governance.DeterministicDeployment.spec.ts` pins the recorded constant to the derivation in CI. Residual risk, accepted: a *hand-deployed* strategy wired to a wrong non-zero address would fail only when a veto executes, after the challenge window. The failure is loud (`GovRecoveryUnauthorized`), and the strategy is repairable through the recovery hatch itself (`upgradeStrategy`). Note the recovery address can always veto its own recovery by self-targeted proposal — pre-existing trust-model property, unchanged by this disposition.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
