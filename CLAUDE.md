# Claude AI Assistant Guidelines - Extended Reference

> **Note**: For quick reference, see [AGENTS.md](./AGENTS.md). For deployment mechanics, testing patterns, cross-chain rules, and developer patterns, see the dedicated docs linked from AGENTS.md. This file provides deeper explanations, historical context, and case studies that do not fit in a quick-reference guide.

## Purpose of This Document

- **[AGENTS.md](./AGENTS.md)**: Concise, actionable rules and checklists for AI code generation.
- **[docs/DEPLOYMENT.md](./docs/DEPLOYMENT.md)**: What to redeploy when, salt / `VERSION` bumps, deterministic addresses, nonce and gas management.
- **[docs/TESTING.md](./docs/TESTING.md)**: Test runners, fork-block hygiene, Arbitrum semantics, useful commands.
- **[docs/DEVELOPER_GUIDE.md](./docs/DEVELOPER_GUIDE.md)**: Storage pattern, common operations, approval patterns, adding adapters/extensions/storage, pitfalls.
- **[docs/CROSSCHAIN.md](./docs/CROSSCHAIN.md)**: Cross-chain address rules and Virtual Supply model.
- **CLAUDE.md (this file)**: "Why" behind the rules, detailed case studies, and historical design decisions.

## Architecture at a Glance

For the full upgrade/redeploy rules, ExtensionsMap salt, `VERSION` bump policy, and deterministic-deployment requirements, see [docs/DEPLOYMENT.md](./docs/DEPLOYMENT.md). The short version:

```
User → Pool Proxy (delegatecall)→ Implementation
                                   ↓ fallback
                                   Extensions (via ExtensionsMap)
                                   ↓ fallback
                                   Adapters (via Authority)
```

- **Pool Proxy**: Fixed user-facing address.
- **Implementation**: Mixin contracts + libraries compiled into one upgradeable contract.
- **Extensions**: Chain-specific, immutable, routed via ExtensionsMap.
- **Adapters**: Protocol integrations, upgradeable via Authority governance.

## Storage Pattern Notes

For the copy-paste pattern and the `-1` slot convention, see [docs/DEVELOPER_GUIDE.md](./docs/DEVELOPER_GUIDE.md). One design note worth keeping here:

```solidity
bytes32 slot = keccak256("pool.proxy.virtual.supply") - 1;
```

The `-1` offset avoids collisions with compiler-assigned mapping/array slots, which are placed at `keccak256(value)`. This is why the convention is `keccak256(namespace) - 1`.

**Testing gotcha:** when a library uses an explicit ERC-7201 struct, calling the library from a test contract manipulates the **test contract's** storage at that slot, not the pool's. Always drive pool state through real pool operations in tests.

## Cross-Chain / Virtual Supply

For the Virtual Supply model and cross-chain NAV rules, see [docs/CROSSCHAIN.md](./docs/CROSSCHAIN.md).

## Common Patterns Explained

### Safe Token Operations

Standard ERC20 is inconsistent: USDT requires an approve reset, some tokens return no bool, and some return `false` instead of reverting. `SafeTransferLib` abstracts all of this. Use it for every token operation.

### NAV Updates and Timing

```solidity
// ❌ May read stale NAV
uint256 nav = ISmartPoolState(address(this)).getPoolTokens().unitaryValue;

// ✓ Forces a fresh NAV computation first
ISmartPoolActions(address(this)).updateUnitaryValue();
uint256 nav = ISmartPoolState(address(this)).getPoolTokens().unitaryValue;
```

NAV-sensitive operations (mint, burn, cross-chain transfers) should update NAV before acting on it. For the exact commands and fork-testing rules, see [docs/TESTING.md](./docs/TESTING.md).

---

## Case Study: Across Bridge Integration

### Design Decision — Two Operation Modes

The Across integration supports **Transfer** mode (NAV-neutral via Virtual Supply) and **Sync** mode (NAV changes naturally, used for donations/rebalancing).

Transfer mode is the default because it gives predictable NAV behavior. Sync mode is available for rebalancing but validates against a tolerance to prevent large NAV manipulation.

### Security Decision — Handler Verification

The destination flow is:

```
SpokePool → MulticallHandler.handleV3AcrossMessage()
            → executes encoded multicall
            → pool.donate() (ECrosschain extension via delegatecall)
```

`handleV3AcrossMessage` is not a pool method. The real entry point is `ECrosschain.donate()`, which runs in pool context with `msg.sender == MulticallHandler`. The donation lock and NAV integrity checks prevent manipulation. The MulticallHandler is a trusted Across contract, and the encoded instructions are created by `AIntents._buildMulticallInstructions()` at deposit time.

### Testing Challenge — Storage Isolation

A test that calls `VirtualStorageLib.updateVirtualSupply(delta)` directly updates the **test contract's** storage, not the pool's, because the library's ERC-7201 struct resolves to the calling contract's slot. Create virtual supply through real operations, e.g.:

```solidity
vm.prank(address(spokePool));
IMulticallHandler(multicallHandler).handleV3AcrossMessage(
    outputToken,
    amount,
    relayer,
    abi.encode(instructions)
);
```

For fork-test patterns and commands, see [docs/TESTING.md](./docs/TESTING.md).

---

## Documentation Philosophy

### Why Separate AGENTS.md and CLAUDE.md?

- **AGENTS.md**: Quick reference optimized for AI code generation — critical rules, common operations, checklists.
- **CLAUDE.md**: Deeper understanding for complex decisions, case studies, and historical context.

### Consolidation

Avoid creating many small files for a single topic. Prefer:

- `README.md`: overview and quick reference
- `IMPLEMENTATION_GUIDE.md`: detailed patterns
- `COMPREHENSIVE_ANALYSIS.md`: deep technical dive

Update existing files rather than creating new ones for each iteration.

---

## Solidity Code Style

For the named-mapping-variable rule and other style notes, see [docs/DEVELOPER_GUIDE.md](./docs/DEVELOPER_GUIDE.md).

---

## Code Comment Philosophy

Source files should contain only what is strictly necessary to understand core functionality:

- NatSpec for all `public`/`external` functions
- `@inheritdoc` for interface implementations
- Brief inline `// why` comments for non-obvious decisions

Design rationale, audit responses, and known limitations belong in `/docs/`. A one-line comment may reference the relevant doc section, e.g. `// see docs/staking/CANTINA_FINDINGS_STATUS.md#RIGO-7`.

---

## Audit Fix Verification Protocol

### The "test failure as signal" rule

When an audit fix causes a previously-passing test to fail, the failure is **always a signal to investigate, never noise to suppress**.

Required steps:

1. Run the full test suite with the fix applied.
2. For each failing test, understand what it was asserting and why the fix breaks it.
3. Determine which is wrong — the test or the fix.
4. Only then either correct the fix or, if the test is genuinely stale, remove it with documented justification.

**Never** silently remove or rewrite a failing test without this analysis.

### Canonical Example: RIGO-14 / RIGO-7

**Audit finding (RIGO-14):** POSM ETH residue publicly sweepable — proposed fix: remove `payable` from `MixinFallback.fallback()`.

When the fix was applied, `test_Donate_WithMsgValue_Reverts` started failing. The initial conclusion was "the fix is wrong" because it was thought adapters need ETH via `msg.value`. Deeper analysis (RIGO-7) reversed that conclusion:

1. `fallback() payable` provides no real capability: `receive()` handles plain ETH independently, and any ETH-carrying call-with-data reverts inside the delegatecall to `ExtensionsMap.getExtensionBySelector` regardless of `fallback()`'s payability.
2. The claim that adapters need `msg.value` contradicts the protocol rule that adapters forward ETH from the vault balance, not from `msg.value` (see [docs/DEVELOPER_GUIDE.md](./docs/DEVELOPER_GUIDE.md)).

The failing test was also wrong: it used `vm.mockCall`, which bypassed the real `CALLVALUE` check in `ExtensionsMap`, so it tested mock behavior rather than production behavior.

**Final outcome:** `payable` was removed from `fallback()`, the fake test was deleted, and the real POSM residue fix was identified as appending `Actions.SWEEP` to adapter command sequences. Full disposition: `docs/staking/CANTINA_FINDINGS_STATUS.md#RIGO-7`.

---

## Resources

- [Rigoblock Documentation](https://docs.rigoblock.com)
- [Deployed Contracts](https://docs.rigoblock.com/readme-2/deployed-contracts-v4)
- [GitHub Repository](https://github.com/RigoBlock/v3-contracts)
- [AGENTS.md](./AGENTS.md)
- [docs/DEPLOYMENT.md](./docs/DEPLOYMENT.md)
- [docs/TESTING.md](./docs/TESTING.md)
- [docs/DEVELOPER_GUIDE.md](./docs/DEVELOPER_GUIDE.md)
- [docs/CROSSCHAIN.md](./docs/CROSSCHAIN.md)
