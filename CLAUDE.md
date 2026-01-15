# Claude AI Assistant Guidelines - Extended Reference

> **Note**: For quick reference, see [AGENTS.md](./AGENTS.md) which contains the essential guidelines. This file provides deeper explanations and context.

## Purpose of This Document

AGENTS.md provides concise, actionable guidelines for AI assistants. This document (CLAUDE.md) provides:
- Extended explanations of architectural decisions
- Detailed examples and patterns
- Historical context for design choices
- In-depth case studies

**When to reference each:**
- **AGENTS.md**: Quick facts, critical rules, common operations
- **CLAUDE.md**: Understanding "why", detailed patterns, case studies

---

## Architecture Deep Dive

### Why Proxy + Extensions + Adapters?

**Problem**: Smart contracts cannot be upgraded without changing address

**Solution**: Proxy pattern with fallback mechanism
- **Pool Proxy**: Fixed address, user-facing entry point
- **Implementation**: Upgradeable logic (via factory)
- **Extensions**: Chain-specific, immutable per deployment (e.g., price oracles with specific feeds)
- **Adapters**: Protocol integrations, upgradeable via governance

**Why separate Extensions and Adapters?**
1. **Extensions** need chain-specific constructor params (oracle feeds, SpokePool addresses)
   - Cannot be deployed with same address across chains
   - Mapped in ExtensionsMap (deployed with chain params)
   - Example: ECrosschain needs chain-specific acrossSpokePool address

2. **Adapters** are protocol integrations that may need updates
   - Uniswap V3/V4 router addresses
   - Governance strategies
   - Staking mechanisms
   - Mapped in Authority (governance can update)

### ERC-7201 Storage Pattern

**Why namespaced storage?**
- Proxy pattern means multiple contracts share storage space
- Traditional storage slots can collide
- ERC-7201 uses `keccak256("unique.namespace")` for isolation

**Critical implementation detail:**
```solidity
// Slot calculation
bytes32 slot = keccak256("pool.proxy.virtual.balances") - 1;

// Why -1? 
// Prevents collision with compiler-assigned slots at keccak256(value)
// Compiler uses keccak256 for mappings/arrays, so we offset by -1
```

**Testing gotcha - ERC-7201 with explicit structs:**
When you define storage as:
```solidity
library VirtualStorageLib {
    struct VirtualBalances {
        mapping(address => int256) balances;
        int256 supply;
    }
    
    function _storage() private pure returns (VirtualBalances storage $) {
        bytes32 slot = VIRTUAL_BALANCES_SLOT;
        assembly { $.slot := slot }
    }
}
```

Each contract calling this library accesses **its own** storage at that slot. Tests calling library functions access the **test contract's storage**, not the pool's storage. This is why we cannot directly manipulate pool storage from tests - we must use actual pool operations.

### Virtual Balance System Explained

**The Problem:**
```
Pool on Arbitrum has 100 USDC (NAV = 100)
Transfer 50 USDC to Optimism
- Arbitrum: 50 USDC left (NAV drops to 50) ❌
- Optimism: 50 USDC received (NAV = 50)
- Total NAV dropped from 100 to 100? No, it's 150! ❌
```

**The Solution - Virtual Balances:**
```
Transfer 50 USDC from Arbitrum to Optimism (Transfer mode)

Arbitrum:
- Physical: 50 USDC
- Virtual: +50 USDC (in base token units)
- NAV calculation: (50 + 50) = 100 ✓

Optimism:
- Physical: 50 USDC
- Virtual: -50 USDC (in base token units)
- NAV calculation: (50 - 50) = 0 ✓

Total NAV: 100 + 0 = 100 ✓
```

**Why two systems (Virtual Supply AND Virtual Balances)?**

Virtual Supply handles edge case:
```
Pool deployed on Arbitrum, totalSupply = 100 tokens
User bridges 20 pool tokens to Optimism
- Arbitrum: totalSupply = 100, virtualSupply = 0
- Optimism: totalSupply = 20, virtualSupply = -20
- Net global supply: 100 + 0 + 20 + (-20) = 100 ✓
```

Without virtual supply:
```
Transfer USDC from Arbitrum to Optimism
Optimism has totalSupply = 20 tokens

How much virtual balance to create?
Need: baseValue / currentNav * 10^poolDecimals
But if we always used virtual balances, couldn't track cross-chain supply!
```

**When to use which:**
- **Virtual Supply**: When reducing pool token holdings on outbound transfer (burn shares on source)
- **Virtual Balance**: When offsetting token balance changes for NAV neutrality

Both are used together to maintain NAV integrity while tracking true economic position.

---

## Common Patterns Explained

### Safe Token Operations

**Why SafeTransferLib?**

Standard ERC20 has inconsistencies:
```solidity
// USDT approve() reverts if allowance > 0
token.approve(spender, 100);  // OK
token.approve(spender, 200);  // REVERTS! ❌

// Some tokens don't return bool
token.transfer(to, amount);  // No return value

// Some tokens return false instead of reverting
bool success = token.transfer(to, amount);
if (!success) { /* need to check! */ }
```

SafeTransferLib handles all cases:
```solidity
token.safeApprove(spender, amount);  // Resets to 0 first if needed
token.safeTransfer(to, amount);      // Reverts on failure regardless of return
```

### NAV Updates and Timing

**When to call updateUnitaryValue()?**

NAV is calculated as:
```
NAV = (total asset value) / totalSupply
```

It changes when:
1. Token prices change
2. Tokens added/removed from pool
3. Fees accrued

**Automatic updates:**
- `deposit()` / `withdraw()` - Always updates NAV
- State-changing operations update if needed

**Manual updates needed:**
- Before reading NAV for validation (if may have changed)
- Before cross-chain transfers (want current NAV)
- When reading for external queries (may be stale)

```solidity
// ❌ Wrong - may read stale NAV
uint256 nav = ISmartPoolState(address(this)).getPoolTokens().unitaryValue;

// ✓ Correct - ensure current NAV
ISmartPoolActions(address(this)).updateUnitaryValue();
uint256 nav = ISmartPoolState(address(this)).getPoolTokens().unitaryValue;
```

---

## Case Study: Across Bridge Integration

### Design Decision - Two Operation Modes

**Why have Transfer AND Sync modes?**

Initial design: Only Transfer mode (always NAV-neutral)
```
Problem: Solver fills with extra tokens (surplus)
- Destination NAV increases
- But we applied negative virtual balance
- Result: NAV appears LOWER than reality ❌
```

Solution: Two modes
1. **Transfer**: Default, NAV-neutral, predictable behavior
2. **Sync**: For donations/rebalancing, allows NAV changes, validates tolerance

**Why not always use Sync?**
- Most users want predictable NAV behavior
- Transfer mode makes cross-chain transfers "just work"
- Sync mode requires understanding NAV implications

### Security Decision - Handler Verification

**Why must handler verify msg.sender?**

Extension called via delegatecall from pool:
```
Malicious actor → Pool.fallback() → delegatecall ECrosschain.handleV3AcrossMessage()
```

In delegatecall context:
- Code runs as if it's part of pool
- `msg.sender` is preserved (the attacker)
- Handler can modify pool storage

**Security requirement:**
```solidity
if (msg.sender != _ACROSS_SPOKE_POOL) revert UnauthorizedCaller();
```

Only Across SpokePool can legitimately call this after fill.

### Testing Challenge - Storage Isolation

**Problem encountered:**
Test tried to directly set virtual balance:
```solidity
// In test
VirtualStorageLib._setVirtualBalance(poolAddress, token, amount);
// Doesn't work! Updates test contract's storage, not pool's storage
```

**Why?**
Library uses ERC-7201 storage with explicit struct:
```solidity
function _storage() private pure returns (VirtualBalances storage $) {
    bytes32 slot = VIRTUAL_BALANCES_SLOT;
    assembly { $.slot := slot }  // $ = storage at this slot IN CALLING CONTRACT
}
```

When test calls library, `$` points to test contract storage at that slot, not pool storage.

**Solution:**
Create virtual balance through actual pool operations:
```solidity
// Use actual protocol operation (donation) to create virtual balance
vm.prank(address(spokePool));
ECrosschain(pool).handleV3AcrossMessage(
    token,
    amount,
    relayer,
    encodeMessage(OpType.Transfer, ...)
);
// Now pool has virtual balance via legitimate operation
```

---

## Testing Patterns

### Fork Testing Best Practices

**When to use forks:**
- Testing with actual deployed contracts
- Integration testing with real protocols (Uniswap, Across, etc.)
- Cross-chain scenarios

**Pattern:**
```solidity
uint256 ethFork = vm.createFork("ethereum", Constants.MAINNET_BLOCK);
uint256 baseFork = vm.createFork("base", Constants.BASE_BLOCK);

// Test cross-chain flow
vm.selectFork(ethFork);
// ... initiate transfer on Arbitrum
bytes memory message = captureMessage();

vm.selectFork(optFbaseForkork);
// ... simulate Across fill on Optimism
vm.prank(address(spokePool));
pool.handleV3AcrossMessage(token, amount, relayer, message);
```

**Critical: Use deployed addresses from Constants.sol**
- Reduces RPC calls (contracts already deployed)
- Ensures realistic testing environment
- Avoids address mismatches

### Unit Testing Libraries

**When libraries show as "uncovered" in codecov:**

Integration tests may use library methods, but codecov needs explicit unit tests:

```solidity
// Library
library TransientStorage {
    function setDonationLock(bool locked) internal { ... }
}

// Integration test (uses library indirectly)
pool.donate(...);  // Internally calls TransientStorage.setDonationLock()

// Codecov: "TransientStorage.setDonationLock() not covered" ❌

// Solution: Add explicit unit test
function test_SetDonationLock() public {
    TransientStorage.setDonationLock(true);
    assertTrue(TransientStorage.getDonationLock());
}
// Now codecov sees direct coverage ✓
```

---

## Documentation Philosophy

### Why Separate AGENTS.md and CLAUDE.md?

**AGENTS.md**: Quick reference optimized for AI code generation
- Critical rules (storage, security)
- Common operations (copy-paste patterns)
- Checklists for validation
- ~400 lines, highly scannable

**CLAUDE.md**: Deeper understanding for complex decisions
- Why rules exist (context)
- Detailed explanations
- Case studies of real problems solved
- ~500 lines, reference material

**Analogy:**
- AGENTS.md = API reference
- CLAUDE.md = Architecture guide

### Documentation Consolidation

**Anti-pattern seen:**
- 15+ .md files for single integration
- Redundant information across files
- Outdated analysis files kept around
- Hard to find current information

**Better approach:**
- README.md: Overview and quick reference
- IMPLEMENTATION_GUIDE.md: Detailed patterns
- COMPREHENSIVE_ANALYSIS.md: Deep technical dive
- Delete outdated files

**Rule of thumb:**
- 3-5 files per integration maximum
- Update existing files, don't create new ones for each iteration
- Move to `/docs/<protocol>/` when complete
- Clean up working documents

---

## Resources

- [Rigoblock Documentation](https://docs.rigoblock.com)
- [Deployed Contracts](https://docs.rigoblock.com/readme-2/deployed-contracts-v4)
- [GitHub Repository](https://github.com/RigoBlock/v3-contracts)
- [Across Integration](./docs/across/)
