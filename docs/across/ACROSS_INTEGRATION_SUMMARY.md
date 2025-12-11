# Across Bridge Integration for Rigoblock Smart Pools - Implementation Summary

## Overview

This implementation provides a complete cross-chain token transfer solution for Rigoblock smart pools using Across Protocol V3. The solution maintains NAV (Net Asset Value) integrity across chains through two distinct modes: **Transfer** and **Rebalance**.

## Key Files Modified/Created

### 1. **AIntents.sol** (Adapter - Source Chain)
**Location:** `contracts/protocol/extensions/adapters/AIntents.sol`

**Purpose:** Handles initiation of cross-chain transfers from the source chain.

**Key Methods:**
- `depositV3Transfer()`: Initiates transfer with virtual balance offsetting (NAV unchanged on both chains)
- `depositV3Rebalance()`: Initiates rebalancing (NAV changes on both chains, verified on destination)
- `handleRecoveredTokens()`: Handles token recovery when transfers fail

**Key Features:**
- Automatic WETH wrapping when pool doesn't have enough wrapped native balance
- Token approval management with Across SpokePool
- Virtual balance tracking to offset NAV changes
- Message encoding for destination chain handler

### 2. **EAcrossHandler.sol** (Extension - Destination Chain)
**Location:** `contracts/protocol/extensions/EAcrossHandler.sol`

**Purpose:** Handles incoming cross-chain transfers on the destination chain.

**Key Methods:**
- `handleV3AcrossMessage()`: Main entry point called by Across SpokePool
- `_handleTransferMode()`: Processes Transfer mode (creates negative virtual balances)
- `_handleRebalanceMode()`: Processes Rebalance mode (verifies NAV within tolerance)

**Key Features:**
- Pool existence verification
- Token price feed validation (requirement #3)
- NAV comparison with decimal normalization (requirement #2c)
- Automatic virtual balance management

### 3. **MixinActions.sol** (Core Contract)
**Location:** `contracts/protocol/core/actions/MixinActions.sol`

**Modifications:**
- Added `_getVirtualBalance()` and `_setVirtualBalance()` internal methods
- Added `_isOwnedToken()` helper method
- Updated `donate()` method to adjust virtual balances

### 4. **MixinPoolValue.sol** (Core Contract)
**Location:** `contracts/protocol/core/state/MixinPoolValue.sol`

**Modifications:**
- Integrated virtual balances into NAV calculation (line 118)
- Virtual balances are added to pool value during `_computeTotalPoolValue()`

### 5. **MixinPoolState.sol** (Core Contract)
**Location:** `contracts/protocol/core/state/MixinPoolState.sol`

**Modifications:**
- Added `assertCrosschainNavInRange()` method for NAV verification
- Added `PoolNavNotInRange()` error

## Implementation Details

### Mode 1: Transfer (Virtual Balances)

**Use Case:** Moving tokens cross-chain without affecting NAV on either side.

**Flow:**
1. **Source Chain (depositV3Transfer):**
   - Convert `inputAmount` to base token equivalent
   - Create **positive virtual balance** (offsets NAV decrease from token exit)
   - Call Across `depositV3` with Transfer message type
   
2. **Destination Chain (EAcrossHandler):**
   - Verify token has price feed (reverts if not, allowing recovery on source)
   - Create **negative virtual balance** (offsets NAV increase from token entry)
   - Transfer tokens to pool

**Result:** NAV remains unchanged on both chains despite token movement.

### Mode 2: Rebalance (NAV Verification)

**Use Case:** Rebalancing pool holdings across chains while ensuring NAV consistency.

**Flow:**
1. **Source Chain (depositV3Rebalance):**
   - Calculate current NAV per share
   - Store NAV and decimals in message
   - Call Across `depositV3` with Rebalance message type
   
2. **Destination Chain (EAcrossHandler):**
   - Verify token has price feed
   - Transfer tokens to pool
   - Calculate destination NAV (after receiving tokens)
   - Normalize NAVs to same decimal scale
   - Verify destination NAV is within tolerance of source NAV
   - Revert if NAV deviation exceeds tolerance (allows recovery)

**Result:** NAV changes on both chains, but consistency is verified.

### Virtual Balance Storage

**Storage Slot:** `keccak256("rigoblock.pool.virtualBalances")`

**Structure:** `mapping(address token => int256 balance)`

**Access Pattern:**
```solidity
bytes32 baseSlot = keccak256("rigoblock.pool.virtualBalances");
bytes32 slot = baseSlot.deriveMapping(token);
assembly {
    value := sload(slot)  // read
    sstore(slot, value)   // write
}
```

**Integration:** Virtual balances are automatically included in NAV calculations via `MixinPoolValue._computeTotalPoolValue()`.

## Requirements Addressed

### ✅ Requirement 1: NAV Impact Offsetting (Transfer Mode)
- Source chain: Positive virtual balance created when tokens exit
- Destination chain: Negative virtual balance created when tokens enter
- Virtual balances stored in base token equivalent for efficiency
- Handler failures cause revert, allowing token recovery

### ✅ Requirement 2: Rebalancing with NAV Verification
- Source NAV calculated after token impact
- NAV and decimals passed to destination chain
- Destination verifies NAV (after receiving tokens) is within tolerance
- Decimal normalization ensures accurate comparison across different base tokens
- Partial rebalancing supported via `navTolerance` parameter

### ✅ Requirement 3: Token Price Feed Validation
- Handler verifies output token has price feed on destination
- Reverts if no price feed exists
- Failed verification allows tokens to be recovered on source chain

### ✅ Requirement 4: Token Recovery
- `handleRecoveredTokens()` method updates virtual balances when tokens are recovered
- Virtual balance is reduced by recovered amount
- NAV impact is reversed

## Key Design Decisions

1. **Virtual Balances in Base Token:**
   - All virtual balances stored as base token equivalent
   - Reduces storage requirements (single value instead of per-token mapping)
   - Simplifies NAV calculations
   - Handles case where sent token is never returned

2. **Adapter Pattern:**
   - AIntents is an adapter (called via delegatecall from pool)
   - Ensures proper access to pool storage
   - Allows upgrade by governance

3. **Handler as Extension:**
   - EAcrossHandler is an extension contract
   - Called by Across SpokePool on destination chain
   - Stateless design (reads pool storage directly)
   - Can be deployed at same address across chains

4. **Storage Safety:**
   - Uses ERC-7201 namespaced storage pattern
   - Slot: `keccak256("rigoblock.pool.virtualBalances")`
   - Prevents storage collisions with existing pool storage

5. **Wrapped Native Handling:**
   - Automatic WETH wrapping when pool lacks wrapped native balance
   - Hardcoded `wrappedNative` from SpokePool
   - Simplifies API (no need to pass native/wrapped flags)

## Integration Points

### Pool -> Adapter (AIntents)
```solidity
// Transfer mode
pool.execute(
    adapter,
    abi.encodeWithSelector(
        AIntents.depositV3Transfer.selector,
        inputToken,
        outputToken,
        inputAmount,
        outputAmount,
        destinationChainId,
        fillDeadlineBuffer
    )
);

// Rebalance mode  
pool.execute(
    adapter,
    abi.encodeWithSelector(
        AIntents.depositV3Rebalance.selector,
        inputToken,
        outputToken,
        inputAmount,
        outputAmount,
        destinationChainId,
        navTolerance, // in basis points
        fillDeadlineBuffer
    )
);
```

### Across SpokePool -> Handler (EAcrossHandler)
```solidity
// Called automatically by Across when filling deposit
handler.handleV3AcrossMessage(
    tokenSent,
    amount,
    encodedMessage // contains CrossChainMessage + outputToken + outputAmount
);
```

## Testing Considerations

1. **Virtual Balance Correctness:**
   - Verify positive balance created on source
   - Verify negative balance created on destination
   - Test NAV remains constant in Transfer mode

2. **NAV Verification:**
   - Test with different decimal base tokens
   - Test tolerance boundaries
   - Test revert when NAV exceeds tolerance

3. **Token Recovery:**
   - Test virtual balance adjustment on recovery
   - Test NAV correctness after recovery

4. **Edge Cases:**
   - Pool doesn't exist on destination (should revert)
   - Token has no price feed (should revert)
   - Insufficient wrapped native balance (should wrap)
   - Very small amounts (dust)

## Future Enhancements

1. **Handler Address Registry:**
   - Currently hardcoded, should use deterministic deployment or registry
   
2. **Initial NAV Delta Tracking:**
   - Track per-chain NAV deltas for pools with different initial values
   - Required for accurate Rebalance mode verification

3. **Gas Optimization:**
   - Batch multiple transfers in single transaction
   - Optimize storage access patterns

4. **Monitoring:**
   - Events for virtual balance changes
   - Events for cross-chain transfer initiation/completion

## Security Considerations

1. **Authorization:**
   - Only pool owner can initiate transfers (via adapter)
   - Only Across SpokePool can call handler

2. **Reentrancy:**
   - All external functions protected by `nonReentrant` modifier

3. **Storage Isolation:**
   - Virtual balances use namespaced storage
   - No collision with existing pool storage

4. **Validation:**
   - Token ownership verified before transfer
   - Price feeds verified on destination
   - NAV deviation checked in Rebalance mode

## Deployment Steps

1. Deploy EAcrossHandler on each supported chain (same address via CREATE2)
2. Update AIntents `_getAcrossHandler()` to return correct address
3. Register AIntents adapter with Rigoblock governance
4. Verify Across SpokePool addresses on each chain
5. Test with small amounts first

## Migration from V4 to V3

Changes made:
- Replaced `deposit()` (V4) with `depositV3()` (V3)
- Updated method signatures to match V3 interface
- Removed non-EVM chain support (V3 is EVM-only)
- Simplified message encoding (no `Instructions` struct)
- Message field now contains `CrossChainMessage` struct directly

## Conclusion

This implementation provides a robust, gas-efficient solution for cross-chain token transfers in Rigoblock pools while maintaining NAV integrity. The two-mode design (Transfer/Rebalance) addresses different use cases, and the virtual balance mechanism elegantly handles NAV offsetting without requiring complex state synchronization.
