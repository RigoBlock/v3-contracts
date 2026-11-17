# AI Agent Guidelines for Rigoblock v3-contracts

Quick reference guide for AI agents working with Rigoblock v3-contracts.

## Quick Facts

- **Language**: Solidity 0.8.37 (protocol core; legacy pins remain at 0.8.17 for the pool proxy, governance factory/proxy, and other pre-upgrade contracts)
- **Framework**: Hardhat (existing tests) + Foundry (new integration tests)
- **Architecture**: Proxy pattern with extensions and adapters
- **Chains**: EVM-compatible (Ethereum, Arbitrum, Optimism, Base, Polygon, BSC, Unichain)

## Critical Rules (NEVER Break)

1. **Storage Layout**: Never reorder/remove storage variables in existing contracts
2. **Extensions/Adapters**: Never add storage (they run via delegatecall in pool context)
3. **Storage Slots**: Always assert new slots in `MixinStorage.sol` constructor (use dot notation)
4. **Security**: Adapter write-access is enforced by `MixinFallback`, NOT by an `onlyPoolOwner` modifier in adapter code. The fallback sets `shouldDelegatecall = msg.sender == pool().owner`: non-owners are `staticcall`ed (any state mutation reverts); only the pool owner is `delegatecall`ed (write mode). Extensions that genuinely need caller restrictions must add explicit `msg.sender` checks.
5. **NAV Integrity**: Cross-chain transfers MUST manage virtual supply
6. **Testing**: Always write/update tests when modifying .sol files - tests must pass
7. **Error Handling**: Use custom errors (`error ErrorName(params)`) instead of revert strings
8. **Override Keyword**: Add `override` to interface implementations - fix compilation warnings
9. **Compilation**: Fix all warnings in new code (legacy warnings acceptable)
10. **Named Mapping Variables**: All new mappings must use named key/value parameters — `mapping(KeyType name => ValueType name)` — as required by Solidity ≥0.8.18 style.
11. **ALWAYS RUN TESTS**: After ANY modification to .sol files or test files, IMMEDIATELY run tests to verify they pass
12. **CODE SIZE**: After ANY change that can alter deployed bytecode (including library edits — libraries compile into every importer), measure the affected contracts' deployed size with the production settings (optimizer 200 runs, no viaIR) via `npx hardhat codesize --skipcompile true`, and update the table in `docs/CODE_SIZE.md` in the same PR. Never merge a contract at or above the 24576-byte limit. `SmartPool` has <300 bytes of headroom — flag any PR that shrinks it further.
13. **NEVER push directly to `development` (or any default branch).** Commits reach `development` ONLY via a pull request, so CI (tests, security checks, coverage) always runs. See [docs/BRANCH_WORKFLOW.md](./docs/BRANCH_WORKFLOW.md) for the safe Git workflow.

## AI Agent Limitations (CRITICAL)

**⚠️ AI-GENERATED SOLIDITY CODE CONTAINS CRITICAL BUGS ⚠️**

- AI agents are NOT proficient at writing secure Solidity code
- **AI agents have significant difficulty with logic problems and reasoning**
- Code produced contains security vulnerabilities and logical flaws
- **AI frequently ignores working solutions and introduces new bugs**
- NEVER consider AI-generated code "ready for deployment" or "audit-ready"
- ALWAYS perform thorough manual security review
- AI may reintroduce bugs even after they're fixed
- AI may make incorrect assumptions not based on specifications
- **AI struggles with complex conditional logic and state management**
- All code must be treated as containing critical vulnerabilities until proven otherwise

**Documentation Issues:**

- AI tends to create excessive .md files instead of updating existing ones
- Consolidate documentation into fewer, well-organized files
- Update existing files rather than creating new ones for each iteration

## Architecture in 30 Seconds

```
User → Pool Proxy (delegatecall)→ Implementation
                                   ↓ fallback
                                   Extensions (via ExtensionsMap)
                                   ↓ fallback
                                   Adapters (via Authority)
```

- **Proxy**: User-facing contract at fixed address
- **Implementation**: Core logic (Mixin contracts + libraries). Can be upgraded via factory. Libraries compile into the implementation bytecode.
- **Extensions**: Immutable per deployment, chain-specific addresses. Routed via ExtensionsMap (selector → extension address). ExtensionsMap address is immutable in the implementation.
- **Adapters**: Upgradeable via governance (Authority). Protocol integrations (Uniswap, Across source, etc.)

For what to redeploy when something changes, ExtensionsMap salt / `VERSION` bump rules, deterministic addresses, nonce management, and live-network gas pricing, see [docs/DEPLOYMENT.md](./docs/DEPLOYMENT.md).

## Key Files

### Core Protocol

- `contracts/protocol/SmartPool.sol` - Main implementation
- `contracts/protocol/core/immutable/MixinConstants.sol` - Storage slots and `VERSION`
- `contracts/protocol/core/immutable/MixinStorage.sol` - Storage assertions
- `contracts/protocol/libraries/StorageLib.sol` - Storage access helpers

### Extension/Adapter Infrastructure

- `contracts/protocol/deps/ExtensionsMap.sol` - Extension selector mapping
- `contracts/protocol/deps/ExtensionsMapDeployer.sol` - CREATE2 deployer
- `contracts/protocol/deps/Authority.sol` - Adapter selector registry
- `contracts/protocol/types/DeploymentParams.sol` - Deployment types

### Extensions (Immutable Mapping)

- `EApps.sol` - Application balance queries
- `EOracle.sol` - Price feeds and token conversions
- `EUpgrade.sol` - Implementation upgrades
- `ECrosschain.sol` - Across bridge destination handler
- `EERC20.sol` - Disabled ERC20 methods (non-transferable shares; keeps SmartPool under the contract size limit)

### Adapters (Upgradeable Mapping)

- `AIntents.sol` - Across bridge source adapter
- `AUniswap.sol` - Uniswap integration
- `AStaking.sol` - GRG staking
- `AGovernance.sol` - Governance voting
- `AMulticall.sol` - Batch transactions

### Oracle System

Rigoblock uses **BackGeoOracle**, a Uniswap V4 hook that provides manipulation-resistant on-chain price feeds via truncated geometric-mean TWAP and automatic backrunning. The `EOracle` extension wraps the hook and exposes `getTwap()`, `convertTokenAmount()`, and `hasPriceFeed()` to the pool. For a full technical overview, see [`docs/oracle/BACKGEOORACLE.md`](docs/oracle/BACKGEOORACLE.md).

## Developer Patterns

For the storage pattern, common operations, token approval patterns, how to add adapters/extensions/storage, gas optimization tips, documentation conventions, and common pitfalls, see [docs/DEVELOPER_GUIDE.md](./docs/DEVELOPER_GUIDE.md).

## Testing

- **Hardhat / Mocha** (`yarn test`): runs the `.ts` specs only.
- **Foundry** (`forge test`): runs all Solidity unit, integration, and fork tests.

For fork-block hygiene, test obsolescence review, Arbitrum `block.number` semantics, useful commands, and required environment variables, see [docs/TESTING.md](./docs/TESTING.md).

## Cross-Chain Considerations

For same-address/different-address rules, Virtual Supply model, and NAV integrity in cross-chain transfers, see [docs/CROSSCHAIN.md](./docs/CROSSCHAIN.md).

## Key Deployed Addresses (Most Chains)

```solidity
address constant AUTHORITY = 0x7F427F11eB24f1be14D0c794f6d5a9830F18FBf1;
address constant FACTORY = 0x4aA9e5A5A244C81C3897558C5cF5b752EBefA88f;
address constant REGISTRY = 0x19Be0f8D5f35DB8c2d2f50c9a3742C5d1eB88907;

// Test pool with assets on multiple chains
address constant TEST_POOL = 0xEfa4bDf566aE50537A507863612638680420645C;

// Staking (Mainnet)
address constant STAKING_PROXY = 0x730dDf7b602dB822043e0409d8926440395e07fE;
address constant GRG_TOKEN = 0x4FbB350052Bca5417566f188eB2EBCE5b19BC964;

// Governance
address constant GOV_PROXY = 0x5F8607739c2D2d0b57a4292868C368AB1809767a;
```

Full list: https://docs.rigoblock.com/readme-2/deployed-contracts-v4

## AI Assistant Checklist

When making changes:

- [ ] Preserve storage layout (never reorder/remove storage)
- [ ] Use existing patterns (extensions, adapters, storage access)
- [ ] Add storage slot assertions if adding new storage (dot notation in names)
- [ ] **Extension changed → bump `extensionsMapSalt`** in `src/utils/constants.ts` and **bump `VERSION`** in `MixinConstants.sol` (see [DEPLOYMENT.md](./docs/DEPLOYMENT.md))
- [ ] Verify security (delegatecall context, access control)
- [ ] **Add `override` keyword** to interface implementations
- [ ] **Fix all compilation warnings** in new code
- [ ] **Write or update tests** and **run them immediately** (`forge test`, `yarn test`)
- [ ] **Check deployed code size** after any bytecode-affecting change and update `docs/CODE_SIZE.md` (see [DEPLOYMENT.md](./docs/DEPLOYMENT.md))
- [ ] **Format with the repo Prettier config** — `npx prettier --write <paths>` (or `yarn fmt:sol:protocol`). Do NOT use `forge fmt` on protocol/test Solidity files.
- [ ] **Use custom errors** instead of revert strings
- [ ] Document known limitations clearly
- [ ] Consider gas optimization (immutables, transient storage)
- [ ] Update deployment scripts if adding contracts
- [ ] Save documentation files in `/docs/` or `/docs/<protocol>/`

**CRITICAL**: After modifying any .sol or .spec.ts file, you MUST run the corresponding tests immediately to verify they pass before proceeding.

## When in Doubt

1. Check existing patterns (especially in `core/` and `extensions/`)
2. Check the dedicated docs above for the topic at hand (`DEPLOYMENT.md`, `TESTING.md`, `DEVELOPER_GUIDE.md`, `CROSSCHAIN.md`); use `CLAUDE.md` only for deep historical case studies
3. Look at `AIntents`/`ECrosschain` as a reference implementation
4. Test on forks before proposing changes
5. Never break storage layout!

## Resources

- **Documentation**: https://docs.rigoblock.com
- **Deployed Addresses**: https://docs.rigoblock.com/readme-2/deployed-contracts-v4
- **GitHub**: https://github.com/RigoBlock/v3-contracts
- **Branch workflow**: [docs/BRANCH_WORKFLOW.md](./docs/BRANCH_WORKFLOW.md)
- **Deployment guide**: [docs/DEPLOYMENT.md](./docs/DEPLOYMENT.md)
- **Testing guide**: [docs/TESTING.md](./docs/TESTING.md)
- **Developer guide**: [docs/DEVELOPER_GUIDE.md](./docs/DEVELOPER_GUIDE.md)
- **Cross-chain guide**: [docs/CROSSCHAIN.md](./docs/CROSSCHAIN.md)
