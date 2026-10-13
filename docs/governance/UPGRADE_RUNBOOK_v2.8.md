# Upgrade runbook — SmartPool v4.4.7 + adapters (v2.8.0–v2.8.2)

This runbook executes the v2.8 train on-chain in two governance proposals per chain
(Proposal 1: `PROPOSAL_1_SMARTPOOL_UPGRADE_v4.4.7.md`, Proposal 2:
`PROPOSAL_2_ADAPTER_REMOVALS.md`).

> **Why two proposals:** a single combined proposal needs 12–16 actions; governance caps
> proposals at `PROPOSAL_MAX_OPERATIONS = 10`
> (`contracts/governance/mixins/MixinConstants.sol:11-12`, enforced in
> `MixinVoting._propose`, `MixinVoting.sol:103`).

## 0. Pre-flight checks (all chains, before anything is deployed)

1. **Work from the v2.8.2 tag.** `git checkout v2.8.2 && forge clean` (the clean matters —
   stale incremental artifacts can produce mismatched CBOR tails, see AGENTS.md). The
   `AGovernance` addition to `src/deploy/deploy_extensions.ts` must be present on the
   deployment branch (cherry-pick it if it is not in the tag).
2. **Confirm nothing from this train is live yet.** `deployments/<chain>/SmartPool.json` and
   `ExtensionsMap.json` must have no `transactionHash`. If any chain already had
   `factory.setImplementation` executed for this train, STOP: the unreleased-train assumption
   no longer holds and VERSION/salt must be re-bumped before continuing.
3. **Verify current Authority selector mappings** (decides whether a legacy AGovernance
   removal action is needed in Proposal 2, and records the old adapter addresses):
   - `Authority.getApplicationAdapter(0x367015bb)` (`propose((address,bytes,uint256)[],string)`)
   - `Authority.getApplicationAdapter(0x56781388)` (`castVote(uint256,uint8)`)
   - `Authority.getApplicationAdapter(0xfe0d94c1)` (`execute(uint256)` — new in this train)
     Authority: `0x7F427F11eB24f1be14D0c794f6d5a9830F18FBf1` on all chains. If `castVote`
     returns a non-zero legacy AGovernance address on a chain, Proposal 2 on that chain needs
     one extra `setAdapter(legacyAGovernance, false)` action.
4. **Identify the whitelister.** Selector re-routing (`removeMethod`/`addMethod`) is
   `onlyWhitelister`; `setAdapter` is `onlyOwner` (governance). Confirm which key holds the
   whitelister role on each chain's Authority and that it is available for Section 1,
   step 3. (If `Authority.isWhitelister(governanceProxy)` ever returns true, the method swap
   could instead be batched into the proposal — it does not on current deployments.)
5. **Record old adapter addresses** from `deployments/<chain>/<Adapter>.json` (current
   on-disk values) — needed for the `setAdapter(old, false)` removals and the whitelister
   swaps.

## 1. Proposal 1 — implementation upgrade + adapter whitelisting

### 1.1 Deploy (per chain)

```bash
yarn deploy-all:extensions <network>   # run from the v2.8.2 checkout (with AGovernance in the script)
```

This single run deterministically deploys, per chain: the new extensions, the new
ExtensionsMap (salt `extensionsMapSalt19`), the SmartPool v4.4.7 implementation (carrying the
map as an immutable), and the upgraded adapters — including **AGovernance**
(`src/deploy/deploy_extensions.ts`, skipped only on HyperEVM). Pre-existing canonical
contracts (Authority, PoolRegistry, factory, ExtensionsMapDeployer) are deterministic no-ops.

Addresses differ per chain where constructor args are chain-specific (`AIntents` takes the
chain's SpokePool, `AUniswap`/`AUniswapRouter` take WETH/UniversalRouter/POSM), and are
identical across chains where they are not (`AMulticall`, `A0xRouter`, `AGovernance`,
`AGmxV2`). Read every address from `deployments/<chain>/<Adapter>.json` — never hardcode.

### 1.2 Whitelist new adapters (governance proposal, per chain)

Build Proposal 1 with the interface app (actions append 1:1, see
`buildCreateProposalData.ts`):

1. UPGRADE_IMPLEMENTATION → `RigoblockPoolProxyFactory.setImplementation(<new SmartPool>)`
   (factory `0x4aA9e5A5A244C81C3897558C5cF5b752EBefA88f`).
2. ADD_ADAPTER → `Authority.setAdapter(<new adapter>, true)`, one action each:
   standard chains: AMulticall, AIntents, AUniswap, AUniswapRouter, A0xRouter (+ AGovernance);
   Arbitrum additionally AGmxV2.

Counts: 6 standard (7 with AGovernance), 7 Arbitrum (8), Unichain 6 (7). All ≤ 10.

> **Timing:** the pool implementation takes effect at `setImplementation`, but adapters are
> only _whitelisted_ by this proposal. Until step 1.3 completes, pools keep routing to the
> old adapter addresses, which remain valid. This is safe — old and new implementations are
> compatible with both adapter generations for the unchanged selectors.

### 1.3 Re-route selectors (whitelister key, per chain — NOT proposal actions)

`setAdapter` only flips the adapter whitelist flag; pool routing reads
`Authority._adapterBySelector` via `getApplicationAdapter(msg.sig)`
(`contracts/protocol/core/sys/MixinFallback.sol:36`). For every selector of every upgraded
adapter, the whitelister executes, in order:

```
Authority.removeMethod(<selector>, <old adapter>)
Authority.addMethod(<selector>, <new adapter>)   # reverts with SELECTOR_EXISTS_ERROR if not removed first
```

New-only selectors (no removal needed) in this train include at minimum
`AGovernance.execute(uint256)` (`0xfe0d94c1`) and any methods added to `IAMulticall` /
`IAUniswapRouter` in PRs #965/#946 — enumerate each adapter's external functions from its
`I*` interface (`contracts/protocol/extensions/adapters/interfaces/`). Helper:

```bash
node -e "
const {ethers} = require('ethers');
const abi = require('./deployments/<chain>/<Adapter>.json').abi;
const iface = new ethers.Interface(abi);
for (const f of iface.fragments) {
  if (f.type === 'function' && !f.constant) console.log(f.selector, f.format());
}"
```

Do the remove/add pairs per selector back-to-back; between `removeMethod` and `addMethod`
that selector is unmapped and pool calls revert with `PoolMethodNotAllowed`. Verify after:

```
Authority.getApplicationAdapter(<selector>) == <new adapter>
```

## 2. Proposal 2 — remove superseded adapter whitelist flags

Execute on each chain **after** Proposal 1 of that chain has executed and its whitelister
swaps are verified (Section 1.3).

Actions: REMOVE_ADAPTER → `Authority.setAdapter(<old adapter>, false)`, one per superseded
adapter (standard: A0xRouter, AIntents, AMulticall, AUniswap, AUniswapRouter; Arbitrum
additionally AGmxV2; plus legacy AGovernance if pre-flight step 3 found one). Counts: 5
standard (6), 6 Arbitrum (7), 5 Unichain — all ≤ 10.

This is hygiene only: the whitelist flag is not read by the pool fallback, and the old
contracts stay deployed as the rollback target.

## 3. HyperEVM (chain 999) — deployer-executed, no proposals

No governance proxy exists at `0x5F86...` on HyperEVM, so the deployer key (which still owns
factory/Authority there) executes directly:

1. `yarn deploy-all:extensions hyperliquid` — deploys the v4.4.7 implementation, new
   extensions/map, and the changed adapters (`AIntents`, `AMulticall`, `AHyperliquid`;
   the pragma-only recompile of `AHyperliquid` shifts its address too).
2. `factory.setImplementation(<new SmartPool>)` — the script ships with this block commented
   out for governance-owned chains; on HyperEVM uncomment/run it
   (`src/deploy/deploy_extensions.ts`, the `setImplementation` block).
3. `Authority.setAdapter(<new adapter>, true)` for the three adapters + whitelister
   `removeMethod`/`addMethod` swaps (same procedure as 1.3).

**Skip `AGovernance` on HyperEVM** — its constructor takes the governance proxy address,
which does not exist there yet. Deploy and register it once the governance proxy has been
created on HyperEVM.

## 4. Post-upgrade notes

- **Unichain:** `AGovernance` was never mapped there — adding it is optional; skipping it
  saves one Proposal 1 action.
- **Sepolia:** optional rehearsal chain; no governance is deployed there, so only Proposal 1
  (with a deployer-owned factory) applies.
- **Rollback:** adapters — re-run the whitelister swap back to the old addresses and
  re-whitelist old adapters (old bytecode remains on-chain). Implementation — a new
  `setImplementation` proposal pointing at the previous implementation.
- **Recovery-key compromise (receiver chains):** the correct response to a compromised
  recovery address is a crosschain `upgradeStrategy` action replacing the strategy with one
  carrying a different recovery address — a fresh strategy has fresh storage, so
  `recoveryRequestedAt` resets. Repeated `rejectRecover` vetoes are the wrong tool: they
  leave the compromised address in place and it can re-request immediately, restarting the
  60-day clock each time. Full operational model: RECOVERY.md.
