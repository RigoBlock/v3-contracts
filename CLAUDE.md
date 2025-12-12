# Claude AI Assistant Guidelines for Rigoblock v3-contracts

This document provides comprehensive guidance for AI assistants working with the Rigoblock v3-contracts codebase.

## Project Overview

Rigoblock v3-contracts is a decentralized asset management protocol built on EVM-compatible chains. The repository contains:

- **Protocol contracts**: Smart pool vaults with proxy pattern, extensions, and adapters
- **Governance contracts**: On-chain governance with strategy and voting mechanisms
- **Staking contracts**: GRG token staking with proof-of-performance rewards
- **Token contracts**: RigoToken (GRG) and inflation mechanisms

## Architecture Principles

### 1. Proxy Pattern with Extensions and Adapters

**Core Components:**
- **SmartPool (Proxy)**: User-facing contract that delegatecalls to implementation
- **Implementation**: Core pool logic with fallback mechanism
- **Extensions**: Called via delegatecall from implementation (stateless, modify caller's storage)
- **Adapters**: Called via delegatecall from implementation (stateless, can be upgraded by governance)

**Key Distinction:**
- **Extensions** are mapped in `ExtensionsMap.sol` (immutable mapping, different addresses per chain)
- **Adapters** are mapped in `Authority.sol` (can be upgraded via governance)
- Both execute in the context of the pool proxy (can modify pool storage)
- Neither should have their own state or be callable directly

**Fallback Chain:**
```
Pool Proxy 
  → delegatecall Implementation 
    → fallback to Extensions (if selector mapped in ExtensionsMap)
    → fallback to Adapters (if selector mapped in Authority)
```

### 2. Deterministic Deployment

**Same Address Across Chains:**
- `Authority.sol`
- `Registry.sol` 
- `RigoblockPoolProxyFactory.sol`
- Core implementation contracts
- Staking suite contracts
- Governance core contracts

**Different Addresses Per Chain:**
- `ExtensionsMap.sol` - because extensions have chain-specific constructor params
- Individual extension contracts (EApps, EOracle, EUpgrade, EAcrossHandler)
- Governance strategy contracts

**Deployment Pattern:**
- Use `ExtensionsMapDeployer.sol` with CREATE2 for deterministic ExtensionsMap deployment
- Pass arbitrary salt to bump version when selectors or mappings change
- Extensions take chain-specific params (e.g., wrappedNative, acrossSpokePool addresses)

### 3. Storage Layout (Critical - Never Break!)

**Storage Slots** (defined in `MixinConstants.sol`):
```solidity
_POOL_INIT_SLOT          = keccak256("pool.proxy.initialization") - 1
_POOL_VARIABLES_SLOT     = keccak256("pool.proxy.variables") - 1
_POOL_TOKENS_SLOT        = keccak256("pool.proxy.token") - 1
_POOL_ACCOUNTS_SLOT      = keccak256("pool.proxy.user.accounts") - 1
_TOKEN_REGISTRY_SLOT     = keccak256("pool.proxy.token.registry") - 1
_APPLICATIONS_SLOT       = keccak256("pool.proxy.applications") - 1
_OPERATOR_BOOLEAN_SLOT   = keccak256("pool.proxy.operator.boolean") - 1
_ACCEPTED_TOKENS_SLOT    = keccak256("pool.proxy.accepted.tokens") - 1
_VIRTUAL_BALANCES_SLOT   = keccak256("pool.proxy.virtualBalances") - 1
```

**NEVER:**
- Reorder storage variables in existing contracts
- Change slot calculations
- Add storage to extensions/adapters (they run in pool context)

**Adding New Storage:**
- Use ERC-7201 namespaced storage pattern
- Calculate slot as `keccak256("unique.namespace.name") - 1`
- Add assertion in `MixinStorage.sol` constructor
- Define constant in `MixinConstants.sol`

### 4. NAV (Net Asset Value) Calculation

**Real-time NAV** (transient storage for gas efficiency):
- Calculated by `MixinPoolValue.sol`
- Includes all owned tokens priced via oracle
- Formula: `NAV = Σ(token_balance * token_price_in_base_token)`
- NAV per share: `unitaryValue = NAV / totalSupply`

**Storage NAV** (persistent):
- Updated via `updateUnitaryValue()` - writes to storage
- Read via `getPoolTokens().unitaryValue` - reads from storage
- **Important**: Always call `updateUnitaryValue()` before reading if you need current NAV

**Virtual Balances** (cross-chain accounting):
- Stored as `mapping(address token => int256 virtualBalance)`
- Used to offset NAV changes from cross-chain transfers
- Positive virtual balance = reduce NAV (tokens locked/sent)
- Negative virtual balance = increase NAV (tokens to be received)

## Working with the Codebase

### File Structure

```
contracts/
├── protocol/
│   ├── SmartPool.sol                    # Main pool proxy
│   ├── core/
│   │   ├── immutable/                   # Storage layout definitions
│   │   │   ├── MixinConstants.sol       # Storage slot constants
│   │   │   ├── MixinStorage.sol         # Storage slot assertions
│   │   │   └── MixinImmutables.sol      # Immutable variables
│   │   └── *.sol                        # Core pool functionality
│   ├── extensions/
│   │   ├── EApps.sol                    # Application balance queries
│   │   ├── EOracle.sol                  # Price feed and conversions
│   │   ├── EUpgrade.sol                 # Implementation upgrades
│   │   ├── EAcrossHandler.sol           # Across bridge handler
│   │   └── adapters/
│   │       ├── AIntents.sol             # Across bridge adapter
│   │       ├── AUniswap.sol             # Uniswap integration
│   │       ├── AStaking.sol             # GRG staking
│   │       └── interfaces/              # Adapter interfaces
│   ├── deps/
│   │   ├── Authority.sol                # Adapter registry
│   │   ├── ExtensionsMap.sol            # Extension selector mapping
│   │   └── ExtensionsMapDeployer.sol    # CREATE2 deployer
│   ├── proxies/
│   │   ├── RigoblockPoolProxy.sol       # Pool proxy implementation
│   │   └── RigoblockPoolProxyFactory.sol # Pool factory
│   ├── interfaces/                      # Protocol interfaces
│   ├── libraries/                       # Shared libraries
│   └── types/                           # Type definitions
├── governance/                          # On-chain governance
├── staking/                            # GRG token staking
└── rigoToken/                          # GRG token
```

### Testing

**Framework:**
- Hardhat + TypeScript for unit tests (existing)
- Foundry for integration and fork tests (new)

**Fork Testing Pattern:**
1. Create fork with `vm.createFork(rpcUrl)`
2. Most contracts already deployed - use their addresses
3. Deploy only new contracts (ExtensionsMap, new adapters/extensions)
4. Use `vm.prank()` to impersonate privileged accounts for setup:
   - Factory owner to upgrade implementation
   - Authority whitelister to add adapter methods
   - Pool owner to execute transactions
5. Simulate cross-chain with multiple forks and `vm.selectFork()`

**Key Test Addresses:**
```solidity
// Deployed on most chains
address constant AUTHORITY = 0x7F427F11eB24f1be14D0c794f6d5a9830F18FBf1;
address constant FACTORY = 0x4aA9e5A5A244C81C3897558C5cF5b752EBefA88f;
address constant REGISTRY = 0x19Be0f8D5f35DB8c2d2f50c9a3742C5d1eB88907;

// Existing pool with assets (use for testing)
address constant TEST_POOL = 0xEfa4bDf566aE50537A507863612638680420645C;
```

## Across Bridge Integration (Case Study)

The Across integration demonstrates key patterns:

### 1. Adapter (AIntents.sol)
- Lives in `extensions/adapters/`
- Initiated by pool owner via `depositV3()`
- Validates input token is owned by pool
- Manages virtual balances on source chain
- Forwards call to Across SpokePool with custom message

### 2. Extension (EAcrossHandler.sol)
- Lives in `extensions/`
- Called by Across SpokePool on destination chain
- **Security**: MUST verify `msg.sender == acrossSpokePool`
- Validates token has price feed
- Manages virtual balances on destination chain
- Handles two modes:
  - **Transfer**: Offset NAV with virtual balances
  - **Rebalance**: Verify NAV within tolerance

### 3. Cross-Chain NAV Integrity

**Problem**: Bridging tokens affects NAV on both chains:
- Source chain: NAV decreases (tokens sent)
- Destination chain: NAV increases (tokens received)

**Solution - Transfer Mode**:
- Source: Create positive virtual balance (+locked tokens in base token)
- Destination: Create negative virtual balance (-received tokens in base token)
- Net effect: NAV neutral on both chains

**Solution - Rebalance Mode**:
- Source: NAV actually changes (performance transferred)
- Destination: Verify NAV matches source (within tolerance)
- Use normalized NAV to handle different base token decimals

### 4. Security Considerations

**Extension Security:**
- Extension called via delegatecall (runs in pool context)
- `msg.sender` is preserved (Across SpokePool)
- MUST verify `msg.sender == acrossSpokePool` to prevent unauthorized calls
- Store acrossSpokePool as immutable (gas efficient)

**Token Recovery:**
- Across V3 lacks direct recovery mechanism
- `speedUpV3Deposit` is unsafe (can modify params after fill)
- **Decision**: Don't implement recovery, document as known limitation
- **Mitigation**: Use reasonable fillDeadline (5-30 minutes)

## Common Tasks

### Adding a New Adapter

1. Create adapter in `contracts/protocol/extensions/adapters/YourAdapter.sol`
2. Create interface in `contracts/protocol/extensions/adapters/interfaces/IYourAdapter.sol`
3. Implement with these requirements:
   - Use `onlyDelegateCall` modifier
   - Store `_IMPLEMENTATION` address in constructor
   - Never add storage (operates in pool context)
   - Use `StorageLib` for pool storage access
4. Add method selectors to `Authority.sol` (via governance)
5. Test with fork tests

### Adding a New Extension

1. Create extension in `contracts/protocol/extensions/YourExtension.sol`
2. Create interface in `contracts/protocol/extensions/adapters/interfaces/IYourExtension.sol`
3. Store chain-specific immutables in constructor
4. Add selector to `ExtensionsMap.sol`
5. Update `ExtensionsMapDeployer.sol` to pass constructor params
6. Update `DeploymentParams.sol` types
7. Deploy with new salt via `ExtensionsMapDeployer`

### Adding Storage

1. **Never add to existing storage slots**
2. Define new namespaced slot:
   ```solidity
   bytes32 internal constant _YOUR_SLOT = 
       bytes32(uint256(keccak256("pool.proxy.your.feature")) - 1);
   ```
3. Add assertion in `MixinStorage.sol` constructor:
   ```solidity
   assert(_YOUR_SLOT == bytes32(uint256(keccak256("pool.proxy.your.feature")) - 1));
   ```
4. Access via:
   ```solidity
   function _getYourValue(address key) private view returns (uint256 value) {
       bytes32 slot = _YOUR_SLOT.deriveMapping(key);
       assembly { value := sload(slot) }
   }
   ```

### Testing Cross-Chain Functionality

```solidity
function testCrossChain() public {
    // Setup source chain
    vm.selectFork(arbFork);
    // ... deploy/configure contracts
    
    // Execute source chain transaction
    vm.prank(poolOwner);
    pool.depositV3(...);
    
    // Simulate Across fill on destination
    vm.selectFork(optFork);
    vm.prank(address(spokePool)); // Critical: prank as SpokePool
    pool.handleV3AcrossMessage(...);
    
    // Verify state on both chains
    vm.selectFork(arbFork);
    assertEq(getVirtualBalance(...), expectedValue);
    
    vm.selectFork(optFork);
    assertEq(getVirtualBalance(...), expectedValue);
}
```

## Important Patterns

### 1. Safe Token Operations

Use `SafeTransferLib` for all token operations:
```solidity
using SafeTransferLib for address;

// Transfer
token.safeTransfer(to, amount);

// Approve (handles USDT-style tokens)
token.safeApprove(spender, amount);  // Auto-resets to 0 if needed
```

### 2. Oracle Integration

Always check price feed availability:
```solidity
require(IEOracle(address(this)).hasPriceFeed(token), "NO_PRICE_FEED");

int256 baseAmount = IEOracle(address(this)).convertTokenAmount(
    token,
    amount.toInt256(),
    baseToken
);
```

### 3. NAV Updates

Update before reading when real-time NAV needed:
```solidity
ISmartPoolActions(address(this)).updateUnitaryValue();
ISmartPoolState.PoolTokens memory poolTokens = ISmartPoolState(address(this)).getPoolTokens();
uint256 currentNav = poolTokens.unitaryValue;
```

### 4. Reentrancy Protection

Use `ReentrancyGuardTransient` for external calls:
```solidity
import {ReentrancyGuardTransient} from "../../libraries/ReentrancyGuardTransient.sol";

contract YourAdapter is ReentrancyGuardTransient {
    function yourMethod() external nonReentrant {
        // ... external calls
    }
}
```

## Code Style

- Follow existing Solidity style (0.8.28)
- Use NatSpec comments for public/external functions
- Inherit docs with `@inheritdoc` when implementing interfaces
- **Use `override` keyword** for methods that implement interface functions
  - Compilation will warn if missing - fix all warnings in new code
  - Legacy code may have warnings - acceptable, but fix when modifying
- Keep functions focused and well-named
- Use libraries for reusable logic
- Prefer immutables over constants for chain-specific values
- **Error Handling**: Use custom errors (e.g., `InvalidOpType()`) instead of revert strings
  - Custom errors save gas and allow parameters for better testing
  - Format: `error ErrorName(param1Type param1, param2Type param2);`
  - Legacy code may still have revert strings - update when modifying

### Testing Requirements

**For all new Solidity contracts:**
1. Create or update unit tests (Hardhat TypeScript in `test/`)
2. Create or update fork tests if applicable (Foundry in `test/`)
3. Tests MUST pass before considering implementation complete
4. Run tests: `npm test` (Hardhat) and `forge test` (Foundry)
5. Fix all compilation warnings in new code

**When modifying existing contracts:**
- Ensure existing tests still pass
- Add tests for new functionality
- Update tests for changed behavior

### Storage Slot Naming Convention

When defining storage slot constants in `MixinConstants.sol`, use **dot notation**:
```solidity
// Correct format - use dots to separate namespace components
bytes32 internal constant _VIRTUAL_BALANCES_SLOT = 
    keccak256("pool.proxy.virtual.balances") - 1;

bytes32 internal constant _CHAIN_NAV_SPREADS_SLOT =
    keccak256("pool.proxy.chain.nav.spreads") - 1;

// NOT this - avoid mixed dots and camelCase
bytes32 internal constant _VIRTUAL_BALANCES_SLOT = 
    keccak256("pool.proxy.virtualBalances") - 1; // ❌
```

**When adding new storage slots:**
1. Define constant in `MixinConstants.sol` with dot notation
2. Add assertion in `MixinStorage.sol` constructor
3. Update storage layout assertions for validation

**Storage slot usage:**
- Adapters can import from `MixinConstants.sol` or define in `StorageLib.sol`
- Extensions import from `MixinConstants.sol` (extensions deployed with new implementation)
- Be mindful: modifying `StorageLib.sol` triggers recompilation of all dependent contracts

### Extensions and shouldDelegatecall

Extensions in `ExtensionsMap.sol` can specify call context via `shouldDelegatecall` return value:

```solidity
function getExtensionBySelector(bytes4 selector) external view 
    returns (address extension, bool shouldDelegatecall) {
    if (selector == _EAPPS_BALANCES_SELECTOR) {
        extension = eApps;
        shouldDelegatecall = true; // Needs write access to pool storage
    } else if (selector == _EORACLE_CONVERT_AMOUNT_SELECTOR) {
        extension = eOracle;
        shouldDelegatecall = false; // Read-only, no state changes
    } else if (selector == _EUPGRADE_UPGRADE_SELECTOR) {
        extension = eUpgrade;
        shouldDelegatecall = msg.sender == StorageLib.pool().owner; // Conditional
    }
}
```

**Security consideration**: If extension needs write access (delegatecall), implement caller verification in the extension itself (e.g., `require(msg.sender == acrossSpokePool)`).

## Deployment

See `src/deploy/` for deployment scripts (TypeScript + Hardhat).

**Key Deployment Steps:**
1. Deploy deterministic contracts via singleton factory
2. Deploy extensions with chain-specific params
3. Deploy ExtensionsMap via ExtensionsMapDeployer with salt
4. Whitelist adapters in Authority (governance vote)
5. Upgrade pool implementation if needed (governance vote)

## Documentation Guidelines

### Where to Save Documentation Files

**General Documentation** (`/docs/`):
- Architecture overviews
- Integration guides
- Design decisions
- Known issues/limitations

**Protocol-Specific Documentation** (`/docs/<protocol>/`):
- Create protocol folder for external integrations (e.g., `/docs/across/`, `/docs/uniswap/`)
- Keep all files related to that integration in its folder
- Examples: implementation summaries, deployment guides, test reports

**Working Files**:
- Update existing .md files rather than creating new ones
- Consolidate related information into single files
- Use clear, descriptive filenames

### Documentation Update Pattern

**CRITICAL: STOP CREATING EXCESSIVE .MD FILES**

When working on a feature or integration:
1. **UPDATE existing files** - do NOT create new files for each iteration
2. Consolidate information into single comprehensive documents
3. Save protocol-specific docs in `/docs/<protocol>/` (e.g., `/docs/across/`)
4. Limit to 3-5 core documentation files maximum per integration
5. Delete temporary/working documents after consolidation

**Avoid**: Creating 15+ .md files. This creates confusion and clutter.

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
- [ ] **Run tests to ensure they pass** (`forge test` for Foundry, `npm test` for Hardhat)
- [ ] Test with forks if cross-chain or integration work
- [ ] Update interfaces and use `@inheritdoc`
- [ ] Follow existing code style and naming
- [ ] **Use custom errors** (`error ErrorName(params)`) instead of revert strings
- [ ] Document known limitations clearly
- [ ] Consider gas optimization (immutables, transient storage)
- [ ] Update deployment scripts if adding contracts
- [ ] Save documentation files in `/docs/` or `/docs/<protocol>/`

## Common Pitfalls to Avoid

1. **Adding storage to extensions/adapters** - They run in pool context, use pool storage
2. **Direct calls to extensions/adapters** - Always called via delegatecall
3. **Forgetting security checks** - Verify msg.sender in delegatecall context
4. **Breaking storage layout** - Never reorder/modify existing storage
5. **Reading stale NAV** - Call updateUnitaryValue() first if need current value
6. **Assuming same addresses across chains** - Extensions are chain-specific
7. **Missing price feed checks** - Always verify hasPriceFeed() for new tokens
8. **Unsafe token operations** - Use SafeTransferLib for USDT compatibility
9. **Not testing on forks** - Integration tests should use actual deployed contracts
10. **Ignoring virtual balances** - Cross-chain transfers must maintain NAV integrity
