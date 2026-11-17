# Deployment Guide

This document covers Rigoblock deployment mechanics: what to redeploy when something changes, how to bump the ExtensionsMap salt and implementation `VERSION`, deterministic cross-chain addresses, nonce management, and live-network gas pricing.

## What to redeploy when something changes

- **Library change (used only by implementation)** (e.g., `NavImpactLib` ratio): redeploy the implementation only. Reuse the existing `ExtensionsMap` by passing the same address to `new SmartPool(authority, existingExtensionsMap, tokenJar)`.
- **Library change (used by an extension)**: the extension must be redeployed because the library is compiled into the extension's bytecode. This requires a new `ExtensionsMap` and therefore a new implementation.
- **Extension change**: new extension + new `ExtensionsMap` + new implementation. The `ExtensionsMap` address is immutable in the implementation bytecode.
- **Adapter change**: new adapter + Authority governance update. No implementation or extension changes are needed.

## ExtensionsMap salt

Bump the salt in `src/utils/constants.ts` (`extensionsMapSalt`) whenever a new `ExtensionsMap` must be deployed. This happens in two cases:

1. The `ExtensionsMap` contract code itself changes (new selectors, new routing logic).
2. The bytecode of **any contract stored in the ExtensionsMap** changes. This includes not only direct edits to an extension's source, but also edits to **any library or shared contract compiled into an extension**, because libraries are compiled into the bytecode of every contract that imports them.

Examples:

- `HyperliquidLib` change → `EAppsHyperliquid` changes → new extension addresses → **bump salt**.
- `GmxLib` change → `EAppsArbitrum`, `EGmxCallback` change → **bump salt**.
- `LighterLib` change → `EAppsLighter` changes → **bump salt**.
- `MixinConstants` / other implementation-only libraries → implementation only → **no salt bump**.

### Decision rule

When you change a library, `grep` for every contract that imports it. If any importer is an extension (anything whose address is stored in the `ExtensionsMap`), the salt **must** be bumped. Never assume "I only touched a library" means extensions are unchanged.

### When NOT to bump

If only the implementation changes and everything compiled into extensions is byte-identical, reuse the existing `ExtensionsMap` address. No redeployment or salt bump is needed.

### Unreleased-train exception

If the salt was already bumped in a previous PR of the same release train and that `ExtensionsMap` was **never deployed** (nothing exists at the computed CREATE2 address on any chain), do **not** bump again — reuse the pending salt. The deploy script's `map.code.length == 0` check only works because the address is empty; once deployed, any further extension-bytecode change requires a fresh bump.

### Automation limitation

The current scripts require manual salt bumps. The salt lives in `src/utils/constants.ts` (e.g. `"extensionsMapSalt15"`); bump the numeric suffix in the same PR that changes an extension (directly or via a compiled-in library). Full automation would need to read the existing `ExtensionsMap`'s immutables (`eOracle()`, `eApps()`, etc.) and compare them with the new deployment params before deciding whether to bump. This is not implemented.

## Version bump

Version bumps are required for **any** change that requires redeploying the implementation. That includes changes compiled into the implementation itself (Mixin contracts, libraries, or constructor parameters) **and extension changes**: an extension redeploy requires a new `ExtensionsMap` (an immutable constructor parameter of the implementation), so a new implementation is compiled with a new `VERSION` even if the implementation source is unchanged.

The salt bump and the `VERSION` bump are independent and both are required for an extension change.

### How to choose the next version

1. **Read the base branch version first.** Open `contracts/protocol/core/immutable/MixinConstants.sol` on the PR's base branch and note the current `VERSION` value.
2. **Choose the next version exactly once per PR**:
   - **Patch** (`4.3.3` → `4.3.4`) for bug fixes, audit fixes, or small non-breaking changes.
   - **Minor** (`4.3.3` → `4.4.0`) for new features, new integrations, or non-breaking additions.
   - **Major** (`4.3.3` → `5.0.0`) for breaking changes.
3. **Apply the chosen version consistently** to:
   - `VERSION` in `contracts/protocol/core/immutable/MixinConstants.sol`.
   - `_REQUIRED_VERSION` in any adapter that requires a minimum implementation version.
   - The `pool.VERSION()` assertion in `test/core/RigoblockPool.Basetoken.spec.ts`.
4. **Do not bump multiple times within the same PR.** If the base branch already has a higher version, use that version without further bumping.
5. **Unreleased-train rule.** If the base branch's version belongs to a previous PR of the same release train whose contracts were **never deployed** (no factory `setImplementation` with that version ever executed on any chain), keep that version — do not burn another number. The version identifies a deployed implementation; merging additional changes before the first deployment of the train does not create a new deployment identity. If the previous train **was** deployed, bump normally.

The `pool.VERSION()` test is the guard that reminds future agents to bump the version when the implementation changes; it must stay in sync with `MixinConstants.sol`.

## Deterministic deployment and cross-chain address parity

- **Same address on every chain is a hard requirement.** Authority is at `0xe35129A1E0BdB913CF6Fd8332E9d3533b5F41472` on all chains, produced by `create2(Safe singleton factory 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7, salt 0, init code)`.
- All production chain ids are declared in `PRODUCTION_CHAIN_IDS` in `rocketh/config.ts` with Safe's singleton factory as `deterministicDeployment`. The `deployScript` wrapper in `rocketh/deploy.ts` throws on any live chain not in that list — never let a deploy fall back to rocketh's default CREATE2 factory. When adding a chain, add its id + Safe factory entry to `rocketh/config.ts`.
- **Hardhat 3 changes the CBOR metadata tail** (`project/` source namespacing — a build-info format contract, not configurable), which changes CREATE2 addresses even though the executable bytecode is identical. `readArtifact` (`rocketh/artifacts.ts`) restores the authoritative tail from `rocketh/canonical-cbor.json` for every contract whose executable code is unchanged, so fresh chains reproduce the established addresses. Only the metadata stamp is canonicalized — the deployed executable code is always what the current toolchain compiled from current sources.
- **Redeploy rule — a solc bump redeploys everything it recompiles, even when the executable bytecode is unchanged.** Bumping solc changes the CBOR metadata even for byte-identical executable code, and the new compiler may carry bug fixes invisible at source level. Each `canonical-cbor.json` entry records the solc version of its authoritative deployment; `readArtifact` refuses to restore blobs when the current build's compiler differs, leaving the fresh metadata in the init code so CREATE2 yields a new address. After deploying the upgrade from the authoritative chain (mainnet), regenerate the tails: `npx hardhat run scripts/generate-canonical-cbor.ts --network hardhat`.

## Shared nonce management

All deploy scripts must call `enableManagedNonce(hre, deployer)` at the top so that `deploy()` and `deployments.execute()` share a single nonce counter.

- The helper intercepts `eth_getTransactionCount` RPC calls and patches `JsonRpcSigner` / `Wallet` `sendTransaction`.
- This makes hardhat-deploy's nonce resolution read from a local counter that advances only when a transaction is actually broadcast, preventing `NONCE_EXPIRED` errors on live RPCs.
- The helper is idempotent; calling it multiple times in the same Hardhat run only initializes the counter once.
- It is automatically disabled on the in-memory `hardhat` network so it does not interfere with unit tests that use snapshots / `evm_revert`.
- If a transaction from a previous run is still pending (e.g., due to a gas spike), the next run will see it in the `pending` nonce count and queue new transactions behind it. Resolve or replace the pending transaction first.

## Gas pricing on live networks

Live network configs in `hardhat.config.ts` set hardcoded EIP-1559 caps (`maxFeePerGas` and `maxPriorityFeePerGas`) per network. This avoids manual per-run fee entry, which is error-prone and can wipe an account with a typo.

- The nonce helper applies these caps to every deployment transaction, drops any conflicting `gasPrice`, and sends the transaction as type-2.
- To adjust fees, edit the network entry in `hardhat.config.ts` and review the values carefully before deploying.
- `maxFeePerGas` is the absolute cap on the total gas fee; on chains with volatile base fees (e.g., Polygon) it should be set high enough to survive spikes.
- `maxPriorityFeePerGas` is the validator tip.
