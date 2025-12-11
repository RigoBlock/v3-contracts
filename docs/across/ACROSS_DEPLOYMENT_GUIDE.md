# Across Bridge Integration - Deployment Guide

## Overview

This guide covers the deployment of the Across bridge integration for Rigoblock smart pools. The integration consists of adapters and extensions that must be deployed on each supported chain.

## Architecture Summary

### Components

1. **AIntents (Adapter)** - Initiates cross-chain transfers from source chain
2. **EAcrossHandler (Extension)** - Handles incoming transfers on destination chain
3. **ExtensionsMap** - Maps handler selectors to extension addresses
4. **ExtensionsMapDeployer** - Deploys ExtensionsMap with deterministic addresses

### Key Design Principles

- **ExtensionsMap:** Same address across all chains (deterministic via CREATE2)
- **Extensions:** Different addresses per chain (constructor params vary)
- **Adapters:** Registered with governance, called via delegatecall from pools
- **Handler:** Called via delegatecall by Across SpokePool when filling deposits

## Prerequisites

### Required Information Per Chain

1. Across SpokePool address
2. Wrapped native token address (WETH, WMATIC, etc.)
3. Rigoblock Authority address
4. Rigoblock ExtensionsMapDeployer address (same across chains)

### Deployment Accounts

- Deployer account with sufficient native currency for gas
- Governance multisig for registration/approval

## Deployment Steps

### Phase 1: Deploy Extensions (Per Chain)

Extensions have different addresses on each chain due to different constructor parameters (wrappedNative, SpokePool).

#### 1. Deploy EAcrossHandler

**Constructor:** None (stateless extension)

```bash
forge create contracts/protocol/extensions/EAcrossHandler.sol:EAcrossHandler \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --verify
```

**Expected Result:** Extension contract address (will differ per chain)

**Verification:**
```bash
cast call $EACROSS_HANDLER "handleV3AcrossMessage(address,uint256,bytes)" \
    --rpc-url $RPC_URL
# Should not revert on selector lookup
```

#### 2. Deploy AIntents (Adapter)

**Constructor:** `address acrossSpokePool`

```bash
forge create contracts/protocol/extensions/adapters/AIntents.sol:AIntents \
    --constructor-args $SPOKE_POOL_ADDRESS \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --verify
```

**Expected Result:** Adapter contract address

**Verification:**
```bash
# Verify SpokePool address
cast call $AINTENTS_ADDRESS "acrossSpokePool()" --rpc-url $RPC_URL

# Verify required version
cast call $AINTENTS_ADDRESS "requiredVersion()" --rpc-url $RPC_URL
# Should return: "HF_4.1.0"
```

### Phase 2: Deploy ExtensionsMap (Per Chain)

ExtensionsMap addresses will be different per chain, but ExtensionsMapDeployer is the same.

#### 3. Deploy ExtensionsMap via Deployer

```javascript
// Using ethers.js or similar
const deployer = await ethers.getContractAt(
    "ExtensionsMapDeployer",
    EXTENSIONS_MAP_DEPLOYER_ADDRESS
);

const params = {
    extensions: {
        eApps: EXISTING_EAPPS_ADDRESS,
        eOracle: EXISTING_EORACLE_ADDRESS,
        eUpgrade: EXISTING_EUPGRADE_ADDRESS,
        eAcrossHandler: EACROSS_HANDLER_ADDRESS // Newly deployed
    },
    wrappedNative: WRAPPED_NATIVE_ADDRESS
};

const salt = ethers.utils.id("v4.1.0-across-integration"); // Arbitrary salt

const tx = await deployer.deployExtensionsMap(params, salt);
const receipt = await tx.wait();

// Get deployed address from event or call
const mapAddress = await deployer.deployedMaps(
    deployer.address,
    ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(
        ["address", "bytes32"],
        [deployer.address, salt]
    ))
);

console.log("ExtensionsMap deployed at:", mapAddress);
```

**Verification:**
```bash
# Verify eAcrossHandler is set
cast call $EXTENSIONS_MAP "eAcrossHandler()" --rpc-url $RPC_URL

# Verify selector mapping
cast call $EXTENSIONS_MAP \
    "getExtensionBySelector(bytes4)" \
    0x$(cast sig "handleV3AcrossMessage(address,uint256,bytes)" | cut -c1-10) \
    --rpc-url $RPC_URL
# Should return: (eAcrossHandler address, true)
```

### Phase 3: Governance Registration

#### 4. Register AIntents Adapter

Submit governance proposal to register adapter:

```solidity
// Governance proposal
IAuthority(AUTHORITY_ADDRESS).setAdapter(
    address(AINTENTS_ADDRESS),
    true // authorized
);
```

**Multi-chain Note:** Must be done on each chain where integration is deployed.

#### 5. Update Pool Implementation (if needed)

If pools need to update their ExtensionsMap reference:

```solidity
// Via pool owner
pool.upgradeImplementation(NEW_IMPLEMENTATION_ADDRESS);
```

**Note:** Only required if existing pools don't automatically use new ExtensionsMap.

## Deployment Addresses Tracking

### Template for Recording Addresses

```yaml
arbitrum:
  chain_id: 42161
  spoke_pool: "0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A"
  wrapped_native: "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1"
  deployments:
    eacross_handler: "0x..." # Deployed address
    aintents_adapter: "0x..." # Deployed address
    extensions_map: "0x..." # Deployed address
  registration:
    adapter_registered: true
    date: "2025-XX-XX"
    tx_hash: "0x..."

optimism:
  chain_id: 10
  spoke_pool: "0x6f26Bf09B1C792e3228e5467807a900A503c0281"
  wrapped_native: "0x4200000000000000000000000000000000000006"
  deployments:
    eacross_handler: "0x..."
    aintents_adapter: "0x..."
    extensions_map: "0x..."
  registration:
    adapter_registered: true
    date: "2025-XX-XX"
    tx_hash: "0x..."
```

## Post-Deployment Verification

### 1. Test Handler Selector Mapping

```bash
# Calculate selector
SELECTOR=$(cast sig "handleV3AcrossMessage(address,uint256,bytes)")
echo "Selector: $SELECTOR"

# Verify mapping in ExtensionsMap
cast call $EXTENSIONS_MAP \
    "getExtensionBySelector(bytes4)" \
    $SELECTOR \
    --rpc-url $RPC_URL
```

**Expected:** Returns (handler address, true)

### 2. Test Adapter Delegate Call Protection

```bash
# Direct call should revert
cast call $AINTENTS_ADDRESS \
    "depositV3(address,address,uint256,uint256,uint256,uint32,bytes)" \
    --rpc-url $RPC_URL
```

**Expected:** Reverts with `DirectCallNotAllowed`

### 3. Test Pool Integration (Optional)

Deploy test pool and execute small transfer:

```javascript
// Via test pool
const pool = await ethers.getContractAt("SmartPool", TEST_POOL_ADDRESS);

const message = ethers.utils.defaultAbiCoder.encode(
    ["tuple(uint8,uint256,uint8,uint256,bool)"],
    [[0, 0, 0, 0, false]] // Transfer mode
);

// Small test transfer
await pool.execute(
    AINTENTS_ADDRESS,
    pool.interface.encodeFunctionData("depositV3", [
        USDC_ADDRESS,
        USDC_ADDRESS_DEST_CHAIN,
        ethers.utils.parseUnits("1", 6), // 1 USDC
        ethers.utils.parseUnits("1", 6),
        DEST_CHAIN_ID,
        300,
        message
    ])
);
```

## Monitoring and Maintenance

### Key Events to Monitor

1. **Source Chain:**
   - `V3FundsDeposited` from Across SpokePool
   - Virtual balance changes in pools

2. **Destination Chain:**
   - `FilledV3Relay` from Across SpokePool
   - Handler execution success/failure

### Health Checks

```bash
# Check adapter SpokePool connection
cast call $AINTENTS_ADDRESS "acrossSpokePool()" --rpc-url $RPC_URL

# Check handler in ExtensionsMap
cast call $EXTENSIONS_MAP "eAcrossHandler()" --rpc-url $RPC_URL

# Verify adapter registration
cast call $AUTHORITY_ADDRESS "isAdapterApproved(address)" $AINTENTS_ADDRESS --rpc-url $RPC_URL
```

## Upgrade Process

### Deploying New Handler Version

1. Deploy new handler contract
2. Deploy new ExtensionsMap with updated handler address
3. Update pools to use new ExtensionsMap (via governance)
4. Old ExtensionsMap remains functional for existing pools

### Deploying New Adapter Version

1. Deploy new adapter contract
2. Register with governance
3. Deprecate old adapter (optional)
4. Pools can choose which adapter to use

## Troubleshooting

### Issue: Handler not callable

**Symptoms:** Transactions revert when Across tries to call handler

**Check:**
```bash
# Verify selector is mapped
cast call $EXTENSIONS_MAP \
    "getExtensionBySelector(bytes4)" \
    $(cast sig "handleV3AcrossMessage(address,uint256,bytes)") \
    --rpc-url $RPC_URL
```

**Solution:** Ensure ExtensionsMap is deployed with correct handler address and selector mapping.

### Issue: Adapter rejected by pool

**Symptoms:** Pool reverts when trying to call adapter

**Check:**
```bash
# Verify adapter is registered
cast call $AUTHORITY_ADDRESS "isAdapterApproved(address)" $AINTENTS_ADDRESS \
    --rpc-url $RPC_URL
```

**Solution:** Submit governance proposal to register adapter.

### Issue: Pool doesn't exist on destination

**Symptoms:** Transfers fail on destination chain

**Expected Behavior:** Across should revert when calling handler on non-existent pool, allowing source chain recovery.

**Verify:** Pool is deployed at same address on destination chain.

## Security Considerations

### 1. ExtensionsMap Verification

- **Critical:** Verify ExtensionsMap source code before deployment
- **Check:** All extension addresses are correct
- **Audit:** Selector mappings are correct

### 2. Adapter Registration

- **Process:** Only governance can register adapters
- **Verify:** Adapter source code before registration
- **Monitor:** Adapter usage after registration

### 3. Handler Safety

- **Design:** Handler has no state, operates in pool context
- **Verify:** Price feed validation prevents rogue tokens
- **Check:** NAV verification in Rebalance mode

### 4. Virtual Balance Integrity

- **Monitor:** Virtual balance changes match transfers
- **Alert:** Unexpected virtual balance divergence
- **Recovery:** Process for clearing orphaned virtual balances

## Support Contacts

- **Technical Issues:** GitHub Issues
- **Deployment Help:** Rigoblock Discord/Telegram
- **Security Concerns:** security@rigoblock.com

## Appendix: Chain-Specific Information

### Arbitrum
- Chain ID: 42161
- SpokePool: `0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A`
- WETH: `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1`

### Optimism
- Chain ID: 10
- SpokePool: `0x6f26Bf09B1C792e3228e5467807a900A503c0281`
- WETH: `0x4200000000000000000000000000000000000006`

### Base
- Chain ID: 8453
- SpokePool: `0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64`
- WETH: `0x4200000000000000000000000000000000000006`

### Polygon
- Chain ID: 137
- SpokePool: TBD
- WMATIC: `0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270`
