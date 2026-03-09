# Granular Delegated Access to Adapter Methods

## Overview

Pool operators can grant specific external addresses write-level access to individual adapter function selectors. This enables **agentic trading** — allowing AI agents or separate trading wallets to interact with pool adapters (swaps, positions, etc.) on behalf of the pool, without requiring the operator's wallet to sign every transaction.

This provides native account abstraction (AA) semantics to vaults regardless of whether the operator wallet implements EIP-7702 or is a simple EOA.

---

## Motivation

Rigoblock pools are smart accounts. Adapters (Uniswap, GMX, etc.) are called via `delegatecall` through the pool fallback when the caller is the pool owner. Everyone else is `staticcall`ed, making any state-mutation revert automatically.

Without delegation, the pool operator must personally sign every adapter interaction. This is impractical for:

- **Agentic AI traders** operating 24/7 with their own keys
- **Separate hot wallets** for active trading vs. cold owner keys for governance
- **Multi-agent setups** where different agents are scoped to different protocols

---

## Design

### Storage

A new ERC-7201 namespace (`pool.proxy.delegation`) stores a `DelegationData` struct with four parallel data structures maintaining two enumerable mappings:

```
selector → [delegated addresses]   (enumerate / revoke-by-selector)
address  → [delegated selectors]   (enumerate / revoke-by-address)
```

Both directions are maintained at O(1) via position-tracked swap-and-pop arrays. The lookup in the fallback is a single SLOAD:

```solidity
delegation().selectorToAddressPosition[msg.sig][msg.sender] != 0
```

### Fallback Gate

```solidity
// Delegation check is first: approved delegates short-circuit here;
// owner falls through to the second check.
// Read mode for everyone else (any state mutation in the adapter reverts).
shouldDelegatecall = delegation().selectorToAddressPosition[msg.sig][msg.sender] != 0 ||
    msg.sender == pool().owner;
```

Non-owners without delegation (and `address(this)`) are routed via `staticcall`; any state mutation reverts automatically — no explicit `onlyOwner` guard needed in adapter code.

### Delegation Struct

```solidity
struct Delegation {
    address delegated; // address receiving or losing access
    bytes4  selector;  // adapter method selector
    bool    isDelegated; // true = grant, false = revoke
}
```

---

## API

### `updateDelegation(Delegation[] calldata delegations)`

Batch grant or revoke (selector, address) pairs. Each entry is processed independently; `isDelegated: true` adds the pair, `false` removes it. Both operations are idempotent.

**Access**: pool owner only.

```solidity
// Grant user2 access to the Uniswap execute() selector
pool.updateDelegation([
    Delegation({
        delegated: agentAddress,
        selector: bytes4(0x3593564c), // execute(bytes,bytes[],uint256)
        isDelegated: true
    })
]);
```

### `revokeAllDelegations(address delegated)`

Atomically revokes every selector previously delegated to `delegated`. Useful when an agent wallet is compromised.

**Access**: pool owner only.

```solidity
pool.revokeAllDelegations(compromisedAgentAddress);
```

### `revokeAllDelegationsForSelector(bytes4 selector)`

Atomically revokes all addresses delegated for `selector`. Useful when an adapter is being replaced by governance.

**Access**: pool owner only.

```solidity
pool.revokeAllDelegationsForSelector(bytes4(0x3593564c));
```

### Events

```solidity
event DelegationUpdated(
    address indexed pool,
    address indexed delegated,
    bytes4  indexed selector,
    bool    isDelegated
);
```

Emitted **only when storage actually changes** — idempotent adds (pair already exists) and idempotent removes (pair not present) are silent. `revokeAll*` bulk calls emit once per previously-present entry.

---

## Read Methods

Two view functions in `ISmartPoolState` / `MixinPoolState`:

```solidity
/// Returns all addresses currently delegated for a selector.
function getDelegatedAddresses(bytes4 selector) external view returns (address[] memory);

/// Returns all selectors delegated to an address.
function getDelegatedSelectors(address delegated) external view returns (bytes4[] memory);
```

These are the minimum useful set: off-chain agents can enumerate their own scope via `getDelegatedSelectors(agentAddress)`, and the operator can audit who has access to a method via `getDelegatedAddresses(selector)`.

---

## Gas Analysis

### Fallback check overhead (non-owner path)

```solidity
// Delegation check first — agents short-circuit here; owner pays both SLOADs.
shouldDelegatecall = delegation().selectorToAddressPosition[msg.sig][msg.sender] != 0 ||
    msg.sender == pool().owner;
```

| Step | Delegated agent | Pool owner | Unauthenticated |
|---|---|---|---|
| Double-mapping slot derivation | 84 gas | 84 gas | 84 gas |
| Delegation SLOAD | ~100 warm / ~2100 cold | ~100 warm / ~2100 cold | ~100 warm / ~2100 cold |
| Agent match → short-circuit | yes | no | no |
| `pool().owner` SLOAD | — | ~100 warm / ~2100 cold | ~100 warm / ~2100 cold |
| **Total (warm)** | **~184 gas** | **~284 gas** | **~284 gas** |
| **Total (cold)** | **~2184 gas** | **~4284 gas** | **~4284 gas** |

Ordering rationale: since agents are expected to transact far more frequently than the owner, placing the delegation check first makes every agent call ~2100 gas cheaper (cold, one fewer SLOAD) at the cost of ~2100 gas per owner call. The net saving across the system is proportional to `(agentCalls − ownerCalls) × 2100 gas`.

Hash derivation breakdown: two `keccak256` over 64 bytes each = 2 × (30 + 12) = **84 gas** (fixed, independent of warm/cold).

### Why cold matters for agents

The EIP-2929 warm/cold distinction resets per transaction. A delegated agent sending one trade per transaction always pays the cold SLOAD cost of 2100 gas for the delegation check. Over 1 M transactions at 30 gwei that is ≈0.13 ETH — negligible.

### Can we make it cheaper?

**Option A — flat bitmap**: Replace `mapping(bytes4 => mapping(address => uint256))` with `mapping(bytes32 => bool)` keyed by `keccak256(abi.encodePacked(selector, addr))`. Reduces slot derivation from 2 × 42 = 84 gas to 1 × 36 + 1 × 42 = **78 gas**. Saves 6 gas. Not worth the added write complexity.

**Option B — client-side EIP-2930 access lists**: The delegation slot for `(msg.sig, msg.sender)` is deterministic and can be pre-included in the transaction access list. This makes the SLOAD warm (100 gas instead of 2100), saving **2000 gas** per transaction at the cost of ~2400 gas for the access list entry — net neutral for a single adapter call, net positive for multiple adapter calls in one tx (e.g. via multicall).

**Option C — `mapping(uint256 → bytes4)` + length instead of `bytes4[]`**: Strictly worse. Array element `i` lives at `keccak256(slot) + i` (pure addition). A mapping would require `keccak256(abi.encode(i, slot))` per element (hash on every access). The dynamic array IS the correct enumerable set pattern.

**Conclusion**: The current design is optimal at the contract level. Delegated agents transacting frequently should use EIP-2930 access lists.

---

## Key Properties

| Property | Details |
|---|---|
| Access control | All write operations: `onlyOwner` |
| Fallback overhead | 1 delegation SLOAD for all callers; owner additionally pays the `pool().owner` SLOAD |
| Enumerable sets | Both directions; swap-and-pop for O(1) removal |
| Idempotent add | Adding an already-delegated pair is a no-op |
| Idempotent remove | Removing a non-existent pair is a no-op |
| Selector scope | Delegation is per-selector; agent scoped to swap ≠ access to other methods |
| Owner is always write | `pool().owner` retains unconditional write access |
| Delegation persists ownership change | Stored in pool storage; survives `setOwner` |

---

## Security Notes

1. **Delegation does NOT elevate privileges beyond owner-level**. A delegated agent can only call the specific adapter selectors it was granted; it cannot call other adapter methods, owner actions, or extension methods.

2. **Adapter write-access is gated in `MixinFallback`, not in adapter code**. Adapter contracts themselves do NOT check `msg.sender`; the fallback enforces the mode (delegatecall vs staticcall).

3. **Extension calls are unaffected**. Extensions (EOracle, ECrosschain, etc.) are always delegatecalled for all callers; they must add their own `msg.sender` checks if caller restriction is needed. Delegation only affects the adapter dispatch path.

4. **Compromised agent wallet**: call `revokeAllDelegations(agentAddress)` to instantly revoke all its permissions. Governance does not need to be involved.

5. **Replaced adapter**: call `revokeAllDelegationsForSelector(selector)` to clean up stale delegations before/after governance upgrades the adapter mapping.

6. **Delegations survive ownership transfer**. The delegation mapping is keyed by selector + address, not by owner identity. A malicious previous owner could install a delegation back-door before calling `setOwner`. The incoming owner MUST audit and clean up delegations on taking control — call `revokeAllDelegations` for every known agent address, or `revokeAllDelegationsForSelector` for each adapter selector, as part of the handover checklist. There is no automatic revocation on `setOwner`.

7. **No privilege escalation via delegation**. Owner actions such as `updateDelegation`, `setOwner`, etc. are dispatched directly by the implementation's ABI, never through `MixinFallback`. A delegation to an owner-action selector has no effect; the call still hits `onlyOwner` and reverts.

---

## Future Extension: Per-Delegation Expiry

Expiry timestamps are not part of the current release (delegations are revocable by the owner at any time). If needed in a future release they can be added **without breaking the existing storage layout**:

```solidity
// Add a 5th field to DelegationData — safe because all fields are mappings
mapping(bytes4 => mapping(address => uint40)) expiryAt; // 0 = never expires
```

The fallback check would become:
```solidity
uint40 expiry = delegation().expiryAt[msg.sig][msg.sender];
bool notExpired = expiry == 0 || expiry > uint40(block.timestamp);
shouldDelegatecall =
    (delegation().selectorToAddressPosition[msg.sig][msg.sender] != 0 && notExpired) ||
    msg.sender == pool().owner;
```

Cost: one additional SLOAD (~2100 gas cold) per agent call. Worth considering against the value of on-chain expiry vs off-chain key rotation.

**NAV guard (rejected)**: a per-call check that halts delegation if pool NAV dropped >X% was considered but rejected. NAV reads are inherently expensive, require storing a baseline at delegation time, and are susceptible to flash-loan manipulation. Slippage protection belongs inside individual adapters, not in the access-control gate.

---

## Use Case: Agentic Trading

```
Pool Operator (cold wallet, owner)
    └── grants delegation: agentAddress => execute.selector (Uniswap)
    └── grants delegation: agentAddress => createIncreaseOrder.selector (GMX)

AI Agent (hot wallet = agentAddress)
    ├── calls pool.execute(commands, inputs, deadline)  → delegatecall ✓
    ├── calls pool.createIncreaseOrder(params)          → delegatecall ✓
    └── calls pool.setOwner(attacker)                  → PoolCallerIsNotOwner() ✗
```

The agent can trade freely within its granted scope. It cannot modify pool settings, transfer ownership, or access adapter methods it was not explicitly granted.

---

## Storage Slot

| Name | Slot |
|---|---|
| `_DELEGATION_SLOT` | `0x1de728329845ca9693f4e251833e4fd20a461e4f39179bee6e55171aedb6dc19` |

Derived as `keccak256("pool.proxy.delegation") - 1` per ERC-7201 convention. Asserted in `MixinStorage` constructor.

---

## Implementation Files

| File | Role |
|---|---|
| `contracts/protocol/libraries/DelegationLib.sol` | Core enumerable bi-directional delegation registry; `add`/`remove` return `bool` |
| `contracts/protocol/types/Delegation.sol` | `Delegation` struct type definition |
| `contracts/protocol/core/immutable/MixinConstants.sol` | `_DELEGATION_SLOT` constant |
| `contracts/protocol/core/immutable/MixinStorage.sol` | `delegation()` accessor + slot assertion |
| `contracts/protocol/core/sys/MixinFallback.sol` | Updated `shouldDelegatecall` check; delegation tested first |
| `contracts/protocol/core/actions/MixinOwnerActions.sol` | `updateDelegation`, `revokeAllDelegations`, `revokeAllDelegationsForSelector` |
| `contracts/protocol/core/state/MixinPoolState.sol` | `getDelegatedAddresses`, `getDelegatedSelectors` |
| `contracts/protocol/interfaces/v4/pool/ISmartPoolOwnerActions.sol` | Write interface (imports `Delegation` from types) |
| `contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol` | Read interface |
| `contracts/protocol/interfaces/v4/pool/ISmartPoolEvents.sol` | `DelegationUpdated` event |
| `contracts/protocol/libraries/StorageLib.sol` | `DELEGATION_SLOT` + `delegation()` for extensions |
| `contracts/test/MockDelegationAdapter.sol` | Test-only adapter for write-gate tests |
| `test/core/RigoblockPool.Delegation.spec.ts` | 32 Hardhat integration tests |
| `test/libraries/DelegationLib.t.sol` | 41 Foundry tests: 27 unit + 7 fuzz + 7 invariant |
