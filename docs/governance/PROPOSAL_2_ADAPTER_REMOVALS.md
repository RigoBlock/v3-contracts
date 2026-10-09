# Proposal 2 — Remove superseded adapter whitelist flags

## Summary

This is the cleanup companion to Proposal 1 (SmartPool v4.4.7 + adapter whitelisting). It
removes the Authority whitelist flags of the adapter contracts superseded by Proposal 1.
Selector routing was already moved to the new adapters by the Authority whitelister as part
of the Proposal 1 runbook (`UPGRADE_RUNBOOK_v2.8.md`, Section 1.3), so this proposal carries
no routing changes — `setAdapter(adapter, false)` only clears the old contracts' whitelist
flag, which the pool fallback never reads.

## On-chain actions per chain

REMOVE_ADAPTER → `Authority.setAdapter(<old adapter>, false)`, one action per superseded
adapter (old addresses recorded in pre-flight step 5 of the runbook):

- Standard chains: `A0xRouter`, `AIntents`, `AMulticall`, `AUniswap`, `AUniswapRouter`
- Arbitrum additionally: `AGmxV2`
- Include the legacy `AGovernance` address as an extra removal **only if** pre-flight step 3
  found one registered in Authority (`getApplicationAdapter(castVote)` returned non-zero).

Action count: 5 on standard chains (6 with legacy AGovernance), 6 on Arbitrum (7), 5 on
Unichain.

## Notes

- Old adapter contracts remain deployed on-chain; this proposal only clears their whitelist
  flag, which keeps them usable as a rollback target (re-whitelist + whitelister swap back).
- Safe to execute at any time after Proposal 1's whitelister swaps are verified; there is no
  expiry and no dependency on pool state.

## References

- `PROPOSAL_1_SMARTPOOL_UPGRADE_v4.4.7.md`
- `UPGRADE_RUNBOOK_v2.8.md`
- `docs/governance/STRATEGY.md`
