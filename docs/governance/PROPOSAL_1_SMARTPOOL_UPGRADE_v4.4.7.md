# Proposal 1 — Upgrade SmartPool implementation to v4.4.7 and register upgraded adapters

## Summary

This proposal upgrades the SmartPool implementation contract to v4.4.7 in the pool proxy
factory and whitelists the upgraded adapter contracts in Authority. The upgrade adapts the
GMX integration to GMX's contract-address breaking change (new DataStore, Router, OrderVault
and related contract addresses), adds an early-revert safety guard in AGmxV2 against future
non-backwards-compatible GMX changes, adds a market-token price-feed validation that prevents
untrackable GMX funding accruals from bricking pool NAV, replaces the handwritten GMX
interfaces with direct imports from the gmx-synthetics submodule, upgrades the Uniswap
integration to Universal Router 2.1.2, and ships the rewritten AGovernance adapter
(Tally/OpenZeppelin-compatible voting surface).

The new implementation carries the new ExtensionsMap (deploy salt 19) as an immutable
constructor parameter, so the map and implementation upgrades land atomically in the single
`setImplementation` action. ExtensionsMap salt was bumped from 16 to 17 (#963), 18 (#946/#965)
and 19 (artifact import fix) across the v2.8.0–v2.8.2 train.

GMX-specific changes are only active where GMX positions exist (Arbitrum). Every chain
receives the same SmartPool implementation bytecode for storage-layout parity; GMX
application state remains reserved and unused where the GMX adapter is not registered.

This proposal only **whitelists** the new adapter addresses via `Authority.setAdapter`. The
companion selector re-routing (`removeMethod`/`addMethod` per selector, executed by the
Authority whitelister) and the removal of the old adapter whitelist flags (Proposal 2) are
tracked in `UPGRADE_RUNBOOK_v2.8.md`.

## On-chain actions per chain

1. `RigoblockPoolProxyFactory.setImplementation(<new SmartPool v4.4.7>)` — 1 action.
2. `Authority.setAdapter(<new adapter>, true)` — 1 action per upgraded adapter:
   - All chains: `AMulticall`, `AIntents`, `AUniswap`, `AUniswapRouter`, `A0xRouter`
   - Arbitrum additionally: `AGmxV2`
   - All chains except HyperEVM: `AGovernance` (deployed for the first time)

Action count: 6 actions on standard chains, 7 on Arbitrum (plus 1 on every chain if
`AGovernance` is included). All new adapter addresses are read from
`deployments/<chain>/<Adapter>.json` after running `yarn deploy-all:extensions <network>`
from the v2.8.2 tag.

HyperEVM is excluded: no governance exists there yet, so the deployer key executes the
factory and Authority updates directly (see runbook).

## Changes

### SmartPool implementation (4.4.4 → 4.4.7)

- **VERSION 4.4.7** (final of the train; intermediate 4.4.5/4.4.6 were never deployed): the
  implementation is recompiled with the updated libraries below, so the factory
  implementation must be updated on every chain even where GMX/Uniswap adapters are unused.

### Extensions (new ExtensionsMap, salt 19)

- **EApps / ENavView / EGmxCallback (Arbitrum):** recompiled with the updated `GmxConstants`
  hardcoded addresses and the submodule-native GMX interfaces (PRs #963, #964). The
  extensions also carry the `NavView` NAV parity aggregation fix and the `AUniswapDecoder`
  refactor (calldata slicing replaces calldata-pointer assembly, fail-closed decoder gaps)
  from the Universal Router 2.1.2 train (PR #965). These are part of the shared extension
  bytecode deployed on every chain.

### Adapters

- **AGmxV2 (Arbitrum only):** `GmxConstants` updated to GMX's new contract addresses, plus an
  early-revert guard so a future non-backwards-compatible GMX change fails loudly at order
  creation (PR #963). Handwritten GMX interfaces deprecated in favor of direct gmx-synthetics
  submodule imports (PR #964). **Adapter-only** fix: `createIncreaseOrder` now requires a pool
  price feed for both market tokens, so funding paid in the non-directional token cannot enter
  NAV untracked and brick `updateUnitaryValue` (PR #968). Selectors and the external GMX API
  surface are unchanged.
- **AUniswapRouter (non-HyperEVM chains):** Universal Router dependency upgraded 2.0.0 →
  2.1.2, adapter compiled with solc 0.8.37 via an isolated forge job, decoder refactor plus
  audit fixes included (PR #965).
- **AMulticall, AIntents, AUniswap, A0xRouter (all non-HyperEVM chains):** recompiled with
  solc 0.8.37 (PR #946 pragma bump); bytecode/metadata changes shift their deployment
  addresses, so they are redeployed and re-whitelisted.
- **AGovernance (all non-HyperEVM chains, first deployment):** rewritten adapter aligned with
  the upgraded governance surface — `propose` returns the proposalId, `castVote` takes OZ/Tally
  `uint8 support`, new payable `execute(uint256)`, plus `onlyDelegateCall` protection
  (PR #946).

## Affected contracts

- SmartPool implementation (v4.4.7)
- ExtensionsMap (salt 19, via immutable constructor parameter)
- EApps, ENavView, EGmxCallback (Arbitrum)
- AMulticall, AIntents, AUniswap, AUniswapRouter, A0xRouter (re-whitelisted)
- AGmxV2 (Arbitrum, re-whitelisted)
- AGovernance (first deployment)

## References

- PR #963 — fix: support gmx breaking changes
- PR #964 — fix: address gmx breaking change
- PR #965 — feat: universal router 2.1.2
- PR #968 — fix: gmx market token feed validation
- PR #946 — feat: crosschain governance (ships the pool-side AGovernance adapter)
- Releases v2.8.0, v2.8.1, v2.8.2 (range v2.7.0...v2.8.2)
