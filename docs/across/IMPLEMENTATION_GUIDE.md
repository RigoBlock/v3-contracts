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
   - Entry point: `donate()` (called via Across MulticallHandler's encoded multicall)
   - `handleV3AcrossMessage()` lives on the Across MulticallHandler (external), not on the pool
   - Writes positive Virtual Supply for Transfer mode
   - Validates NAV integrity

3. **VirtualStorageLib.sol** (Storage Library)
   - Path: `contracts/protocol/libraries/VirtualStorageLib.sol`
   - Manages Virtual Supply storage slot
   - Provides `getVirtualSupply()` and `updateVirtualSupply()`

4. **NavImpactLib.sol** (NAV Validation)
   - Path: `contracts/protocol/libraries/NavImpactLib.sol`
   - Validates Sync mode NAV impact
   - Enforces 1/MINIMUM_SUPPLY_RATIO effective supply constraint (currently 5% with MINIMUM_SUPPLY_RATIO = 20)

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

The destination flow uses the Across MulticallHandler (external contract):

```
SpokePool → MulticallHandler.handleV3AcrossMessage(outputToken, amount, relayer, encodedInstructions)
  → MulticallHandler executes encoded multicall:
    1. pool.donate(token, 1, params)     // Phase 1: snapshot balance + NAV
    2. IERC20.transfer(pool, amount)     // Transfer tokens to pool
    3. handler.drainLeftoverTokens(...)  // Drain any surplus
    4. pool.donate(token, amount, params) // Phase 2: process donation + VS update
```

`ECrosschain.donate()` is the actual pool entry point (called via delegatecall):

```solidity
function donate(
  address token,
  uint256 amount,
  DestinationMessageParams calldata params
) external {
  // `donate()` is non-payable; the actual token transfer to the pool happens between the
  // two `donate()` calls (or the pool already holds the tokens). Native currency reads use
  // address(this).balance so the extension stays consistent with the CrosschainLib allowlist:
  // address(0) is rejected in phase 2 by `CrosschainLib.isAllowedCrosschainToken`, not by an
  // early phase-1 guard. This keeps the option open if the library is ever updated to accept
  // native ETH on the destination side, without the extension contradicting that allowlist.
  // Phase 1 (amount == 1): Store initial balance, NAV and total assets
  // Phase 2: Process donation
  //   - Validate balance delta >= amount
  //   - If Transfer mode: write positive VS (_updateVirtualSupply)
  //   - If Sync mode: no VS adjustment
  //   - If shouldUnwrapNative: cannot unwrap the pool's base token itself
  //   - Validate NAV integrity
  //   - Validate NAV per share did not decrease (protects against interleaved
  //     mint/burn or any future operation that changes the supply/asset ratio)
}
```

**Security note:** the phase-2 donation enforces `navParams.unitaryValue >= storedNav`.
This closes the "phantom virtual supply" attack where a caller interleaves a share-issuing
operation (e.g. `mint`) between the two `donate()` phases: the interleaved mint satisfies
the asset-equality check with the caller's own deposit, but the subsequent positive
virtual-supply write would lower NAV per share. The per-share invariant detects that
manipulation without having to enumerate callers.

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
  NetAssetsValue memory navParams = ISmartPoolActions(address(this))
    .updateUnitaryValue();
  uint8 poolDecimals = StorageLib.pool().decimals;

  // Calculate shares leaving: outputValue / NAV
  int256 sharesLeaving = ((outputValueInBase * (10 ** poolDecimals)) /
    navParams.unitaryValue).toInt256();

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

// Must maintain at least 1/MINIMUM_SUPPLY_RATIO of total supply (currently 5%)
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

### Permissionless Entry Point

`ECrosschain.donate()` is intentionally a permissionless function: it can be called by the
Across MulticallHandler, an escrow contract, or anyone with whitelisted tokens to donate.
Restricting callers to Across infrastructure would not close the attack surface, because
the same two-phase sequence can be encoded as a valid cross-chain message from another
chain. The safety invariant therefore lives inside the donation logic, not in a caller
allowlist.

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

| Operation            | Gas Cost |
| -------------------- | -------- |
| Source VS write      | ~5,000   |
| Destination VS write | ~5,000   |
| NAV calculation      | ~3,000   |
| Total per transfer   | ~13,000  |

## Deployment

1. Deploy AIntents adapter with SpokePool address
2. Register in Authority
3. Deploy ECrosschain extension with SpokePool and MulticallHandler addresses
4. Register in ExtensionsMap
5. Test end-to-end transfer
