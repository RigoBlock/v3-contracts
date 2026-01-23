# Technical Implementation Guide

## Overview

This guide covers the technical implementation of the Across Protocol integration for Rigoblock Smart Pools using the VS-only model.

## Architecture

### Components

1. **AIntents.sol** (Source Chain Adapter)
   - Path: `contracts/protocol/extensions/adapters/AIntents.sol`
   - Initiates cross-chain transfers via Across `depositV3()`
   - Writes negative Virtual Supply for Transfer mode
   - Validates NAV impact for Sync mode

2. **ECrosschain.sol** (Destination Chain Extension)
   - Path: `contracts/protocol/extensions/ECrosschain.sol`
   - Receives tokens via `handleV3AcrossMessage()`
   - Writes positive Virtual Supply for Transfer mode
   - Validates NAV integrity

3. **VirtualStorageLib.sol** (Storage Library)
   - Path: `contracts/protocol/libraries/VirtualStorageLib.sol`
   - Manages Virtual Supply storage slot
   - Provides `getVirtualSupply()` and `updateVirtualSupply()`

4. **NavImpactLib.sol** (NAV Validation)
   - Path: `contracts/protocol/libraries/NavImpactLib.sol`
   - Validates Sync mode NAV impact
   - Enforces 1/MINIMUM_SUPPLY_RATIO effective supply constraint (currently 12.5% with MINIMUM_SUPPLY_RATIO = 8)

## Transfer Flow

### Source Chain (AIntents)

```solidity
function depositV3(AcrossParams calldata params) external {
    // 1. Validate bridgeable token pair
    CrosschainLib.validateBridgeableTokenPair(params.inputToken, params.outputToken);
    
    // 2. Parse source parameters
    SourceMessageParams memory sourceParams = abi.decode(params.message, (SourceMessageParams));
    
    // 3. Build multicall instructions for destination
    Instructions memory instructions = _buildMulticallInstructions(params, sourceParams);
    
    // 4. Handle source-side adjustments
    if (sourceParams.opType == OpType.Transfer) {
        _handleSourceTransfer(params);  // Writes negative VS
        params.depositor = EscrowFactory.deployEscrow(address(this), OpType.Transfer);
    } else if (sourceParams.opType == OpType.Sync) {
        NavImpactLib.validateNavImpact(...);  // No VS adjustment
        params.depositor = address(this);
    }
    
    // 5. Execute Across deposit
    _acrossSpokePool.depositV3{value: sourceParams.sourceNativeAmount}(...);
}
```

### Destination Chain (ECrosschain)

```solidity
function handleV3AcrossMessage(
    address tokenSent,
    uint256 amount,
    address relayer,
    bytes memory message
) external {
    // 1. Validate caller is SpokePool
    require(msg.sender == address(_spokePool), OnlySpokePoolAllowed());
    
    // 2. Store initial state for validation
    token.setDonationLock(amount);
    TransientStorage.storeNav(currentNav);
    TransientStorage.storeAssets(currentAssets);
    
    // 3. Execute multicall instructions
    // ... (transfer tokens to pool, call donate())
    
    // 4. In donate(): Apply virtual adjustments
    if (params.opType == OpType.Transfer) {
        _handleTransferMode(...);  // Writes positive VS
    } else if (params.opType == OpType.Sync) {
        _handleSyncMode();  // No VS adjustment
    }
}
```

## Virtual Supply Management

### Storage

```solidity
// VirtualStorageLib.sol
bytes32 internal constant VIRTUAL_SUPPLY_SLOT = 
    bytes32(uint256(keccak256("pool.proxy.virtual.supply")) - 1);

function getVirtualSupply() internal view returns (int256 virtualSupply) {
    bytes32 slot = VIRTUAL_SUPPLY_SLOT;
    assembly { virtualSupply := sload(slot) }
}

function updateVirtualSupply(int256 adjustment) internal {
    bytes32 slot = VIRTUAL_SUPPLY_SLOT;
    int256 current;
    assembly { current := sload(slot) }
    int256 updated = current + adjustment;
    assembly { sstore(slot, updated) }
}
```

### Source Chain Logic

```solidity
// AIntents._handleSourceTransfer()
function _handleSourceTransfer(AcrossParams memory params) private {
    // Get output value in base token terms
    (uint256 outputValueInBase, ) = _getOutputValueInBase(params);

    // Update NAV and get pool state
    NetAssetsValue memory navParams = ISmartPoolActions(address(this)).updateUnitaryValue();
    uint8 poolDecimals = StorageLib.pool().decimals;

    // Calculate shares leaving: outputValue / NAV
    int256 sharesLeaving = ((outputValueInBase * (10 ** poolDecimals)) / navParams.unitaryValue).toInt256();

    // Write negative VS
    (-sharesLeaving).updateVirtualSupply();
}
```

### Destination Chain Logic

```solidity
// ECrosschain._handleTransferMode()
function _handleTransferMode(...) private {
    // Convert amount to base token value
    uint256 amountValueInBase = IEOracle(address(this)).convertTokenAmount(token, amount.toInt256(), baseToken).toUint256();

    // Get current VS state
    int256 currentVS = VirtualStorageLib.getVirtualSupply();
    uint256 storedNav = TransientStorage.getStoredNav();

    // Calculate shares arriving: amountValue / NAV
    int256 sharesArriving = ((amountValueInBase * (10 ** poolDecimals)) / storedNav).toInt256();

    // If negative VS exists, clear it first
    if (currentVS < 0) {
        // Arriving shares may partially or fully clear negative VS
        sharesArriving.updateVirtualSupply();
    } else {
        // Add positive VS
        sharesArriving.updateVirtualSupply();
    }
}
```

## NAV Calculation with Virtual Supply

### Effective Supply

```solidity
// MixinPoolTokens._calculateUnitaryValue()
int256 virtualSupply = VirtualStorageLib.getVirtualSupply();

// Effective supply includes virtual supply (can be negative or positive)
int256 effectiveSupply = int256(poolTokens().totalSupply) + virtualSupply;

// Safety check: effective supply must be positive
if (effectiveSupply <= 0) {
    // Use graceful degradation
    return nav / totalSupply;  // Ignore VS
}

unitaryValue = nav / uint256(effectiveSupply);
```

### 10% Constraint

```solidity
// NavImpactLib.validateNavImpact()
int256 currentVS = VirtualStorageLib.getVirtualSupply();
int256 sharesLeaving = (outputValue * 10**decimals / nav).toInt256();

int256 newVS = currentVS - sharesLeaving;  // More negative
int256 effectiveSupply = int256(totalSupply) + newVS;

// Must maintain at least 1/MINIMUM_SUPPLY_RATIO of total supply (currently 12.5%)
require(effectiveSupply >= int256(totalSupply / MINIMUM_SUPPLY_RATIO), EffectiveSupplyTooLow());
```

## Operation Types

### Transfer Mode (NAV-neutral)

```
Source:
  - Writes negative VS (shares leaving)
  - NAV unchanged (value decreases, supply decreases proportionally)
  - Uses escrow as depositor (for NAV-neutral refunds)

Destination:
  - Writes positive VS (shares arriving)
  - NAV unchanged (value increases, supply increases proportionally)
  - Validates NAV integrity
```

### Sync Mode (NAV-impacting)

```
Source:
  - No VS adjustment
  - NAV decreases (tokens leave, supply unchanged)
  - Pool is depositor (direct refund)

Destination:
  - No VS adjustment
  - NAV increases (tokens arrive, supply unchanged)
  - Validates within tolerance
```

## Security Considerations

### Caller Verification

```solidity
// ECrosschain.donate()
require(msg.sender == address(_spokePool) || msg.sender == _multicallHandler, OnlySpokePoolAllowed());
```

### Donation Lock

```solidity
// Prevent reentrancy and manipulation
function setDonationLock(uint256 amount) internal {
    if (amount == 1) {
        // First call - store state
        TransientStorage.storeNav(currentNav);
        return;
    }
    // Second call - process donation
    require(getDonationLock() > 0, NoDonationInProgress());
}
```

### NAV Manipulation Detection

```solidity
// Validate no unexpected NAV changes during donation
require(navParams.netTotalValue == expectedAssets, NavManipulationDetected(expectedAssets, navParams.netTotalValue));
```

## Testing

### Unit Tests

```bash
# Run all Across tests
forge test --match-path "test/extensions/*" -vv

# Run specific VS model tests
forge test --match-contract VSOnlyModelTest -vvv
```

### Fork Tests

```bash
# Test on Arbitrum fork
forge test --match-path test/extensions/AIntentsRealFork.t.sol --fork-url $ARBITRUM_RPC_URL -vvv
```

## Gas Costs

| Operation | Gas Cost |
|-----------|----------|
| Source VS write | ~5,000 |
| Destination VS write | ~5,000 |
| NAV calculation | ~3,000 |
| Total per transfer | ~13,000 |

## Deployment

1. Deploy AIntents adapter with SpokePool address
2. Register in Authority
3. Deploy ECrosschain extension with SpokePool and MulticallHandler addresses
4. Register in ExtensionsMap
5. Test end-to-end transfer
