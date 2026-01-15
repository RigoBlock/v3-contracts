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
4. **Security**: Extensions MUST verify `msg.sender` in delegatecall context
5. **NAV Integrity**: Cross-chain transfers MUST manage virtual balances
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
bytes32 internal constant _VIRTUAL_BALANCES_SLOT = 
    bytes32(uint256(keccak256("pool.proxy.virtual.balances")) - 1);

// NOT this - avoid mixed dots and camelCase
bytes32 internal constant _WRONG_SLOT = 
    bytes32(uint256(keccak256("pool.proxy.virtualBalances")) - 1); // ❌

// In MixinStorage.sol constructor - assert the slot calculation
assert(_VIRTUAL_BALANCES_SLOT == bytes32(uint256(keccak256("pool.proxy.virtual.balances")) - 1));

// Access in contracts
function _getValue(address key) private view returns (uint256 value) {
    bytes32 slot = _VIRTUAL_BALANCES_SLOT.deriveMapping(key);
    assembly { value := sload(slot) }
}

function _setValue(address key, uint256 value) private {
    bytes32 slot = _VIRTUAL_BALANCES_SLOT.deriveMapping(key);
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
- Source: `virtualBalance[baseToken] += sentAmount` (in base token)
- Dest: `virtualBalance[baseToken] -= receivedAmount` (in base token)

**Solution - Rebalance Mode** (NAV changes):
- Source: NAV changes naturally (performance transferred)
- Dest: Verify `|destNav - sourceNav| <= tolerance`

**Implementation**:
```solidity
// Virtual balance storage
bytes32 slot = _VIRTUAL_BALANCES_SLOT.deriveMapping(token);

// Get
assembly { value := sload(slot) }

// Set
assembly { sstore(slot, value) }
```

## Security Checklist

When modifying code:

- [ ] Extensions verify `msg.sender` (preserved in delegatecall)
- [ ] No storage in extensions/adapters (use pool storage)
- [ ] New storage slots asserted in MixinStorage
- [ ] Safe token operations (SafeTransferLib)
- [ ] Price feed checked before token operations
- [ ] NAV updated before reading (if need current value)
- [ ] Reentrancy protection for external calls
- [ ] Virtual balances managed for cross-chain transfers
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
3. **Forgetting security checks** - Verify msg.sender in delegatecall context
4. **Breaking storage layout** - Never reorder/modify existing storage
5. **Reading stale NAV** - Call updateUnitaryValue() first if need current value
6. **Assuming same addresses across chains** - Extensions are chain-specific
7. **Missing price feed checks** - Always verify hasPriceFeed() for new tokens
8. **Unsafe token operations** - Use SafeTransferLib for USDT compatibility
9. **Not testing on forks** - Integration tests should use actual deployed contracts
10. **Ignoring virtual balances** - Cross-chain transfers must maintain NAV integrity
11. **CHANGING CONSTANTS.SOL ADDRESSES** - The addresses in Constants.sol are the CORRECT deployed addresses for fork testing. NEVER change them without verification. Always refer to Constants.sol as the source of truth.
12. **ALWAYS USE CONSTANTS.SOL IMPORTS** - NEVER hardcode addresses or block numbers in test files. ALWAYS import from Constants.sol to ensure consistency and reduce RPC calls. Examples:
    - Use `Constants.ARB_USDC` not `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`
    - Use `Constants.AUTHORITY` not hardcoded authority addresses
13. **DUPLICATING STORAGE SLOTS OR CONSTANTS** - NEVER duplicate hardcoded storage slots, addresses, or other constants across multiple files. ALWAYS define them in a single authoritative location (library or shared constants file) and import/reference them. This prevents inconsistencies when values need to be updated. Examples:
    - Storage slots: Define in the library (e.g., VirtualStorageLib.VIRTUAL_BALANCES_SLOT) and reference from there
    - Chain-specific addresses: Define in libraries (e.g., CrosschainLib) or shared types, not in multiple contracts
    - If a value must be duplicated for technical reasons (e.g., immutable in constructor), document clearly which is the source of truth
