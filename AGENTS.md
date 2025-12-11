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
3. **Storage Slots**: Always assert new slots in `MixinStorage.sol` constructor
4. **Security**: Extensions MUST verify `msg.sender` in delegatecall context
5. **NAV Integrity**: Cross-chain transfers MUST manage virtual balances

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
- `EAcrossHandler.sol` - Across bridge destination handler

### Adapters (Upgradeable Mapping)
- `AIntents.sol` - Across bridge source adapter
- `AUniswap.sol` - Uniswap integration
- `AStaking.sol` - GRG staking
- `AGovernance.sol` - Governance voting
- `AMulticall.sol` - Batch transactions

## Storage Pattern

**All storage uses ERC-7201 namespaced pattern:**

```solidity
// In MixinConstants.sol
bytes32 internal constant _YOUR_SLOT = 
    bytes32(uint256(keccak256("pool.proxy.your.namespace")) - 1);

// In MixinStorage.sol constructor
assert(_YOUR_SLOT == bytes32(uint256(keccak256("pool.proxy.your.namespace")) - 1));

// Access in contracts
function _getValue(address key) private view returns (uint256 value) {
    bytes32 slot = _YOUR_SLOT.deriveMapping(key);
    assembly { value := sload(slot) }
}

function _setValue(address key, uint256 value) private {
    bytes32 slot = _YOUR_SLOT.deriveMapping(key);
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
uint256 arbFork = vm.createFork(vm.envString("ARBITRUM_RPC_URL"));
uint256 optFork = vm.createFork(vm.envString("OPTIMISM_RPC_URL"));

// Switch to fork
vm.selectFork(arbFork);

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
- Individual extensions (EApps, EOracle, EUpgrade, EAcrossHandler)
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

- [ ] Extensions verify `msg.sender` (preserved in delegatecall)
- [ ] No storage in extensions/adapters (use pool storage)
- [ ] New storage slots asserted in MixinStorage
- [ ] Safe token operations (SafeTransferLib)
- [ ] Price feed checked before token operations
- [ ] NAV updated before reading (if need current value)
- [ ] Reentrancy protection for external calls
- [ ] Virtual balances managed for cross-chain transfers

## Gas Optimization Tips

- Use `immutable` for chain-specific constants (acrossSpokePool, wrappedNative)
- Use transient storage for temporary values (ReentrancyGuardTransient)
- Batch read storage into memory structs
- Cache storage reads in loops

## Documentation

- NatSpec all public/external functions
- Use `@inheritdoc` for interface implementations
- Document known limitations clearly (see AIntents.sol token recovery)
- Keep inline comments minimal and focused on "why" not "what"

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
3. Look at AIntents/EAcrossHandler as reference implementation
4. Test on forks before proposing changes
5. Never break storage layout!

## Additional Resources

- Main docs: https://docs.rigoblock.com
- Across integration: docs/across/
- Deployed contracts: https://docs.rigoblock.com/readme-2/deployed-contracts-v4
- GitHub: https://github.com/RigoBlock/v3-contracts
