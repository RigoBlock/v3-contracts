# AI Agent Guidelines for Rigoblock v3-contracts

Quick reference guide for AI agents working with Rigoblock v3-contracts codebase.

## Quick Facts

- **Language**: Solidity 0.8.28
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
10. **ALWAYS RUN TESTS**: After ANY modification to .sol files or test files, IMMEDIATELY run tests to verify they pass

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
- **Implementation**: Core logic, can be upgraded
- **Extensions**: Immutable per deployment, chain-specific addresses
- **Adapters**: Upgradeable via governance

## Key Files

### Core Protocol
- `contracts/protocol/SmartPool.sol` - Main implementation
- `contracts/protocol/core/immutable/MixinConstants.sol` - Storage slots
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

### Adapters (Upgradeable Mapping)
- `AIntents.sol` - Across bridge source adapter
- `AUniswap.sol` - Uniswap integration
- `AStaking.sol` - GRG staking
- `AGovernance.sol` - Governance voting
- `AMulticall.sol` - Batch transactions

## Storage Pattern

**All storage uses ERC-7201 namespaced pattern with dot notation:**

```solidity
// In MixinConstants.sol - use dots to separate namespace components
bytes32 internal constant _VIRTUAL_SUPPLY_SLOT = 
    bytes32(uint256(keccak256("pool.proxy.virtual.supply")) - 1);

// NOT this - avoid mixed dots and camelCase
bytes32 internal constant _WRONG_SLOT = 
    bytes32(uint256(keccak256("pool.proxy.virtualSupply")) - 1); // ❌

// In MixinStorage.sol constructor - assert the slot calculation
assert(_VIRTUAL_SUPPLY_SLOT == bytes32(uint256(keccak256("pool.proxy.virtual.supply")) - 1));

// Access in contracts
function _getValue(address key) private view returns (uint256 value) {
    bytes32 slot = _VIRTUAL_SUPPLY_SLOT;
    assembly { value := sload(slot) }
}

function _setValue(address key, uint256 value) private {
    bytes32 slot = _VIRTUAL_SUPPLY_SLOT.deriveMapping(key);
    assembly { sstore(slot, value) }
}
```

## Common Operations

### Read Pool State
```solidity
import {StorageLib} from "../../libraries/StorageLib.sol";

Pool memory pool = StorageLib.pool();
address baseToken = pool.baseToken;
address owner = pool.owner;
uint8 decimals = pool.decimals;
```

### Update NAV
```solidity
// ALWAYS update before reading if you need current NAV
ISmartPoolActions(address(this)).updateUnitaryValue();

ISmartPoolState.PoolTokens memory poolTokens = 
    ISmartPoolState(address(this)).getPoolTokens();
uint256 currentNav = poolTokens.unitaryValue;
```

### Safe Token Operations
```solidity
using SafeTransferLib for address;

token.safeTransfer(to, amount);
token.safeTransferFrom(from, to, amount);
token.safeApprove(spender, amount); // Handles USDT-style tokens
```

### Check Price Feed
```solidity
require(
    IEOracle(address(this)).hasPriceFeed(token),
    "Token must have price feed"
);
```

### Convert Token Amounts
```solidity
int256 baseAmount = IEOracle(address(this)).convertTokenAmount(
    inputToken,
    inputAmount.toInt256(),
    baseToken
);
```

## Adding New Components

### Token Approval Patterns for External Protocol Integrations

**CRITICAL**: The approval pattern MUST match the target protocol's scoping mechanism.
Verify the target's token flow before writing approval code.

**Pattern 1 — Target uses Permit2** (e.g., Uniswap via AUniswapRouter):
```solidity
// Layer 1: One-time persistent ERC20 → Permit2 (checked with threshold)
if (IERC20(token).allowance(address(this), address(_permit2)) < type(uint96).max) {
    token.safeApprove(address(_permit2), type(uint256).max);
}
// Layer 2: Per-call Permit2.approve with block-scoped expiration
_permit2.approve(token, target, type(uint160).max, 0); // expiration=0 → current block only
```

**Pattern 2 — Target does NOT use Permit2** (e.g., 0x AllowanceHolder via A0xRouter):
```solidity
// Per-call: approve exact amount before call, reset to 1 after success
token.safeApprove(address(target), amount);

try target.exec{value: value}(...) returns (bytes memory result) {
    token.safeApprove(address(target), 1); // reset to 1 (keeps slot warm for gas savings)
    return result;
} catch { ... } // revert unwinds the approval automatically
```

**How to determine which pattern to use:**
1. Read the target protocol's docs for their token transfer mechanism
2. If target supports Permit2 → Pattern 1 (persistent ERC20 + per-call Permit2.approve)
3. If target uses standard ERC20 transferFrom → Pattern 2 (per-call approve + reset)
4. ALWAYS use `safeApprove` for USDT compatibility (force-reset then approve)
5. For native ETH: forward via `{value: value}` — no ERC20 approval needed

**Gas optimization — approval reset to 1, not 0:**
- Resetting to 0 clears storage → next swap pays 20000 gas (zero → non-zero SSTORE)
- Resetting to 1 keeps slot warm → next swap pays 5000 gas (non-zero → non-zero SSTORE)
- Always reset to 1 unless there's a specific reason to fully clear

**Native ETH handling in adapters (CRITICAL):**
- NEVER use `msg.value` to forward ETH in adapter calls
- The adapter runs via delegatecall — `msg.value` comes from the CALLER, not the pool
- The pool is the vault; derive the ETH value from calldata parameters
- Example: `uint256 value = token.isAddressZero() ? amount : 0;`
- Then: `target.exec{value: value}(...)` — sends from pool's own balance
- Same pattern used in AUniswapRouter: `_uniswapRouter.execute{value: params.value}(...)`
- For `InsufficientNativeBalance` check: compare derived `value` to `address(this).balance`

**Testing requirements for new integrations:**
- Test all swap directions: ETH→Token, Token→ETH, Token→Token
- Test with USDT (special approval behavior)
- Test on fork with real deployed contracts (not just mocks)
- Verify allowance is 1 (not 0) after each successful call (for Pattern 2)
- Verify revert unwinds approval state correctly
- Verify ETH swaps use pool balance, NOT caller's msg.value

### New Adapter
1. Create `contracts/protocol/extensions/adapters/YourAdapter.sol`
2. Create interface in `adapters/interfaces/IYourAdapter.sol`
3. Add `onlyDelegateCall` modifier
4. Store `_IMPLEMENTATION = address(this)` in constructor
5. Use `StorageLib` for pool storage access
6. Add methods to `Authority.sol` (via governance)

### New Extension
1. Create `contracts/protocol/extensions/YourExtension.sol`
2. Create interface in `extensions/adapters/interfaces/IYourExtension.sol`
3. Take chain-specific params in constructor (store as immutable)
4. Add selector to `ExtensionsMap.sol` with `shouldDelegatecall` flag
5. Update `ExtensionsMapDeployer.sol` to pass params
6. Update `DeploymentParams.sol` types
7. Deploy with new salt

### New Storage
1. Define slot in `MixinConstants.sol`:
   ```solidity
   bytes32 internal constant _YOUR_SLOT = 
       bytes32(uint256(keccak256("pool.proxy.your.feature")) - 1);
   ```
2. Assert in `MixinStorage.sol` constructor:
   ```solidity
   assert(_YOUR_SLOT == bytes32(uint256(keccak256("pool.proxy.your.feature")) - 1));
   ```
3. Access via assembly with `deriveMapping()` for nested mappings

## Testing

### Unit Tests (Hardhat)
```bash
yarn test
```

### Integration Tests (Foundry)
```bash
forge test
```

### Fork Testing Pattern
```solidity
// Create forks
uint256 ethFork = vm.createSelectFork("ethereum", Constants.MAINNET_BLOCK);
uint256 baseFork = vm.createSelectFork("base", Constants.BASE_BLOCK);

// Use existing contracts (already deployed)
IRigoblockPoolProxyFactory factory = IRigoblockPoolProxyFactory(FACTORY);

// Prank for privileged operations
vm.prank(factoryOwner);
factory.setImplementation(newImplementation);

vm.prank(poolOwner);
pool.someOperation();

// Simulate Across SpokePool calling handler
vm.prank(address(spokePool));
pool.handleV3AcrossMessage(...);
```

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

## Cross-Chain Considerations

### Same Address Across Chains
- Authority, Registry, Factory
- Pool proxies (if deployed with same params)
- Core implementations
- Staking suite, Governance core

### Different Address Per Chain
- ExtensionsMap (extensions have chain-specific params)
- Individual extensions (EApps, EOracle, EUpgrade, ECrosschain)
- Governance strategy

### NAV Integrity in Cross-Chain Transfers

**Problem**: Bridging affects NAV on both chains

**Solution - Transfer Mode** (NAV neutral):
- Source: Writes **negative Virtual Supply** (shares = outputValue / NAV)
- Dest: Writes **positive Virtual Supply** (shares = receivedValue / NAV)
- NAV unchanged on both chains (effectiveSupply adjusts proportionally)

**Solution - Sync Mode** (NAV changes):
- No virtual supply adjustments
- NAV changes naturally (tokens leave source, arrive at destination)
- Use for donations/rebalancing

**Implementation**:
```solidity
// Virtual supply storage (single slot per pool)
bytes32 slot = VIRTUAL_SUPPLY_SLOT;

// Get current virtual supply
int256 vs;
assembly { vs := sload(slot) }

// Update virtual supply
int256 newVs = vs + delta;
assembly { sstore(slot, newVs) }
```

## Security Checklist

When modifying code:

- [ ] Adapter write-access gated by `MixinFallback.fallback()` (`shouldDelegatecall = msg.sender == pool().owner` — non-owners get `staticcall`)
- [ ] Extensions with caller restrictions verify `msg.sender` explicitly (extensions are always delegatecalled for all callers)
- [ ] No storage in extensions/adapters (use pool storage)
- [ ] New storage slots asserted in MixinStorage
- [ ] Safe token operations (SafeTransferLib)
- [ ] Price feed checked before token operations
- [ ] NAV updated before reading (if need current value)
- [ ] Reentrancy protection for external calls
- [ ] Virtual supply managed for cross-chain transfers
- [ ] **Tests written/updated for modified functionality**
- [ ] **Tests pass** (`forge test` or `yarn test`)
- [ ] **Custom errors used** (not revert strings)

## Gas Optimization Tips

- Use `immutable` for chain-specific constants (acrossSpokePool, wrappedNative)
- Use transient storage for temporary values (ReentrancyGuardTransient)
- Batch read storage into memory structs
- Cache storage reads in loops

## Documentation

- NatSpec all public/external functions
- Use `@inheritdoc` for interface implementations
- Document known limitations clearly (see docs/across/KNOWN_ISSUES_AND_EDGE_CASES.md)
- Keep inline comments minimal and focused on "why" not "what"

### Documentation File Management

**Where to Save Documentation**:
- General docs → `/docs/`
- Protocol-specific (Across, Uniswap, etc.) → `/docs/<protocol>/`
- Working documents → Update existing files, don't create many small files

**Workflow**:
1. Create or update single comprehensive document
2. Update as work progresses
3. Move to `/docs/` subfolder when complete
4. Clean up temporary/working documents

**Avoid**: Creating many .md files in root directory - consolidate instead.

## Useful Commands

```bash
# Compile
forge build
yarn compile

# Test
forge test -vvv
yarn test

# Test specific file
forge test --match-path test/extensions/AcrossIntegrationFork.t.sol -vvv

# Test with fork
forge test --fork-url $ARBITRUM_RPC_URL -vvv

# Coverage
yarn coverage

# Format
forge fmt
yarn prettier:write

# Deploy (see src/deploy/)
yarn deploy --network arbitrum
```

## Environment Variables

Required for fork tests:
```bash
ARBITRUM_RPC_URL=https://...
OPTIMISM_RPC_URL=https://...
BASE_RPC_URL=https://...
```

## When in Doubt

1. Check existing patterns (especially in core/ and extensions/)
2. Refer to CLAUDE.md for detailed explanations
3. Look at AIntents/ECrosschain as reference implementation
4. Test on forks before proposing changes
5. Never break storage layout!

## Additional Resources

- Main docs: https://docs.rigoblock.com
- Across integration: docs/across/
- Deployed contracts: https://docs.rigoblock.com/readme-2/deployed-contracts-v4
- GitHub: https://github.com/RigoBlock/v3-contracts
### Documentation Update Pattern

When working on a feature or integration:
1. Create or update a single comprehensive document (e.g., `INTEGRATION_GUIDE.md`)
2. Update as work progresses rather than creating multiple versions
3. Move to appropriate `/docs/` subfolder when complete
4. Clean up temporary/working documents

**Avoid**: Creating many small .md files in root directory - consolidate instead.

## Resources

- **Documentation**: https://docs.rigoblock.com
- **Deployed Addresses**: https://docs.rigoblock.com/readme-2/deployed-contracts-v4
- **GitHub**: https://github.com/RigoBlock/v3-contracts
- **Across Integration**: docs/across/ (cross-chain bridge integration)

## AI Assistant Checklist

When making changes:

- [ ] Preserve storage layout (never reorder/remove storage)
- [ ] Use existing patterns (extensions, adapters, storage access)
- [ ] Add storage slot assertions if adding new storage (dot notation in names)
- [ ] Verify security (delegatecall context, access control)
- [ ] **Add `override` keyword** to interface implementations
- [ ] **Fix all compilation warnings** in new code (not required for legacy code)
- [ ] **Write or update tests** (unit tests, integration tests, fork tests)
- [ ] **IMMEDIATELY RUN TESTS after ANY code change** (`forge test` for Foundry, `yarn test` for Hardhat)
- [ ] **Run tests to ensure they pass** (`forge test` for Foundry, `npm test` for Hardhat)
- [ ] Test with forks if cross-chain or integration work
- [ ] Update interfaces and use `@inheritdoc`
- [ ] Follow existing code style and naming
- [ ] **Use custom errors** (`error ErrorName(params)`) instead of revert strings
- [ ] Document known limitations clearly
- [ ] Consider gas optimization (immutables, transient storage)
- [ ] Update deployment scripts if adding contracts
- [ ] Save documentation files in `/docs/` or `/docs/<protocol>/`

**CRITICAL**: After modifying any .sol or .spec.ts file, you MUST run the corresponding tests immediately to verify they pass before proceeding.

## Common Pitfalls to Avoid

1. **Adding storage to extensions/adapters** - They run in pool context, use pool storage
2. **Direct calls to extensions/adapters** - Always called via delegatecall
3. **Adapter access control misunderstanding** — There is NO `onlyPoolOwner` modifier in adapter code. Write-mode gate lives in `MixinFallback`: `shouldDelegatecall = msg.sender == pool().owner`, so non-owners are routed via `staticcall` (state writes revert). Extensions always run via `delegatecall` for all callers, so they DO need explicit `msg.sender` checks when caller restriction is required.
4. **Breaking storage layout** - Never reorder/modify existing storage
5. **Reading stale NAV** - Call updateUnitaryValue() first if need current value
6. **Assuming same addresses across chains** - Extensions are chain-specific
7. **Missing price feed checks** - Always verify hasPriceFeed() for new tokens
8. **Unsafe token operations** - Use SafeTransferLib for USDT compatibility
9. **Not testing on forks** - Integration tests should use actual deployed contracts
10. **Ignoring virtual supply** - Cross-chain transfers must maintain NAV integrity via VS
11. **CHANGING CONSTANTS.SOL ADDRESSES** - The addresses in Constants.sol are the CORRECT deployed addresses for fork testing. NEVER change them without verification. Always refer to Constants.sol as the source of truth.
12. **ALWAYS USE CONSTANTS.SOL IMPORTS** - NEVER hardcode addresses or block numbers in test files. ALWAYS import from Constants.sol to ensure consistency and reduce RPC calls. Examples:
    - Use `Constants.ARB_USDC` not `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`
    - Use `Constants.AUTHORITY` not hardcoded authority addresses
13. **DUPLICATING STORAGE SLOTS OR CONSTANTS** - NEVER duplicate hardcoded storage slots, addresses, or other constants across multiple files. ALWAYS define them in a single authoritative location (library or shared constants file) and import/reference them. This prevents inconsistencies when values need to be updated. Examples:
    - Storage slots: Define in the library (e.g., VirtualStorageLib.VIRTUAL_SUPPLY_SLOT) and reference from there
    - Chain-specific addresses: Define in libraries (e.g., CrosschainLib) or shared types, not in multiple contracts
    - If a value must be duplicated for technical reasons (e.g., immutable in constructor), document clearly which is the source of truth
14. **WRONG APPROVAL PATTERN FOR EXTERNAL PROTOCOLS** - Before writing approval code, verify whether the target protocol uses Permit2 or standard ERC20 transferFrom:
    - If target uses Permit2 → persistent ERC20 approval + per-call Permit2.approve (Pattern 1)
    - If target uses standard ERC20 → per-call approve exact amount + reset to 1 (Pattern 2)
    - NEVER assume both patterns are interchangeable. Read the protocol's docs first.
    - See "Token Approval Patterns" section in "Adding New Components" for full details and code samples.
15. **USING msg.value IN ADAPTERS** - Adapters run via delegatecall in the pool's context. `msg.value` is what the CALLER sent, NOT the pool's balance. The pool is the vault — derive the ETH value from calldata params (e.g., `value = token == address(0) ? amount : 0`) and forward from pool's own balance (`target.exec{value: value}(...)`). See AUniswapRouter and A0xRouter for reference.
16. **RESETTING APPROVAL TO 0** - When resetting ERC20 approval after a call, set to 1 (not 0). Setting to 0 clears the storage slot; the next swap pays 20000 gas to write zero→non-zero. Setting to 1 keeps the slot warm, so the next swap costs only 5000 gas (non-zero→non-zero). Always prefer `safeApprove(target, 1)` over `safeApprove(target, 0)`.
17. **AVOID ASSEMBLY — USE TYPES AND abi.decode** - Do NOT use inline assembly unless explicitly told to optimize a specific code path. Assembly is error-prone (off-by-one bugs are common and hard to audit). Prefer:
    - `abi.decode(data[offset:offset+size], (Type))` for calldata extraction
    - `bytes4(abi.decode(data[:32], (bytes32)))` to extract a packed selector from calldata
    - `IInterface.FUNCTION.selector` instead of `bytes4(keccak256("FUNCTION(param_types)"))`
    - Solidity calldata slicing (`data[a:b]`) over manual `calldataload` math
    - Assembly is acceptable ONLY for: raw error propagation (`revert(add(d,32),mload(d))`), extracting `bytes4` from `bytes memory` (no Solidity cast exists), and ERC-7201 storage slot access.
18. **USE .selector INSTEAD OF keccak256 HASHING** - ALWAYS use `IInterface.functionName.selector` to obtain function selectors. NEVER use `bytes4(keccak256("functionName(paramTypes)"))` — it is fragile (typos in the string silently produce wrong selectors) and not type-checked by the compiler. If the interface doesn't exist locally, vendor a minimal interface with just the function signatures needed. Example: `ISettlerActions.RFQ.selector` not `bytes4(keccak256("RFQ(address,((address,uint256),uint256,uint256),...)"))`
19. **LOW-LEVEL CALLS IN TESTS** - NEVER use `(bool success, bytes memory data) = target.call(abi.encodeCall(...))` in tests. Always use typed interface calls: `IInterface(target).method(...)`. For expected reverts, use `vm.expectRevert(expectedError)` or `try IInterface(target).method(...) { revert("should fail"); } catch (bytes memory err) { /* check err */ }`. Low-level calls bypass Solidity's type checking and make tests harder to read and audit.
20. **APP ACTIVATION: only when creating non-token external positions** - Call `StorageLib.activeApplications().storeApplication(uint256(Applications.X))` ONLY when the adapter creates an EXTERNAL POSITION that lives outside the pool's ERC-20 wallet and must be valued by EApps. Examples that NEED activation: AGmxV2 (opens DataStore perpetual positions), AUniswapRouter (creates UniV4 LP NFT positions). Examples that DO NOT need activation: A0xRouter (pure swap — output tokens land in pool wallet and are tracked on arrival), AIntents/AcrossBridge (funds leave the pool via bridge; no position held on-chain). The rule: if there is no on-chain struct/position to value at NAV time, storeApplication is not needed.
21. **ADAPTER INTERFACE SELECTORS MUST MATCH THE TARGET PROTOCOL EXACTLY** — When an adapter wraps an external protocol (e.g., GMX, Uniswap, 0x), the `IAdapter` interface MUST expose the SAME function signatures (and therefore selectors) as the underlying protocol interface. This allows the GMX/Uniswap/etc. API to be used directly with minimal changes. Rules:
    - Copy the EXACT parameter list from the protocol's interface — never wrap flat params into a struct, and never omit params.
    - If a parameter must be overridden for security (e.g., `address receiver` that must always be `address(this)`), KEEP it in the interface but leave the variable name blank (`address`), and ignore the caller-supplied value in the implementation. Document the override in the NatSpec.
    - Do NOT introduce wrapper structs to bundle existing protocol params — this changes the selector and breaks ABI compatibility.
    - Exception: if the adapter intentionally splits a protocol function into multiple calls for type-safety (e.g., `createIncreaseOrder` / `createDecreaseOrder` instead of a single `createOrder`), the split is acceptable when the parameter TYPE is preserved (same `CreateOrderParams` struct from the protocol).

## GMX v2 Integration

See `docs/gmx/` for the full GMX integration guide. Key rules for AI agents:

- `GmxLib` returns **native collateral tokens** (not WETH). See `docs/gmx/nav-accounting.md`.
- Always call `_trackToken(collateralToken)` in `createIncreaseOrder`. See `docs/gmx/architecture.md#token-tracking`.
- `ARBITRUM_CHAIN_ID` is defined in `GmxLib` — never duplicate it.
- The chain guard is the `GMX_V2_POSITIONS` activation bit, not a `block.chainid` check in `GmxLib`.
- For P&L fork tests, mock the Chainlink oracle BEFORE `_executeOrder`. See `docs/gmx/architecture.md#common-pitfalls`.- **32-position cap**: `assertPositionLimitNotReached` blocks NEW positions (non-matching market+collateral+direction) when 32 are open. Increasing an EXISTING position is allowed at any count. The NAV loop uses `type(uint256).max` — it reads ALL positions, never just 32.
- **No NAV blind spots**: both pending-order collateral (in GMX OrderVault) and executed-position collateral are always fully counted in NAV. The 32 cap is a gas-protection heuristic only.