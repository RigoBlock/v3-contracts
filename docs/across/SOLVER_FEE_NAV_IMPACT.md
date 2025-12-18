# Across Solver Fee NAV Impact

## Issue Description

Cross-chain transfers via Across Protocol create a small permanent NAV overvaluation due to solver fees not being accounted for in virtual balance calculations.

## Root Cause

**Virtual Balance Mechanism**: 
- Source chain: Creates positive virtual balance for full sent amount
- Destination chain: Creates negative virtual balance for received amount
- Problem: `sent_amount > received_amount` due to solver fees

**Example**:
```
User sends: 1000 USDC
Solver fee: 5 USDC  
User receives: 995 USDC

Source virtual balance: +1000 USDC
Destination virtual balance: -995 USDC
Net virtual balance: +5 USDC (permanent NAV inflation)
```

## Current Impact

- Small permanent NAV overvaluation equal to solver fees
- Typically 0.1-2% of transfer amount depending on route and conditions
- Only affects Transfer mode operations (Sync mode intended to change NAV)
- Accumulates over time with multiple cross-chain transfers

## Proposed Solutions

### 1. Message Enhancement (Recommended)
Add original sent amount to `DestinationMessage`:
```solidity
struct DestinationMessage {
    OpType opType;
    uint256 sourceChainId;
    uint256 sourceNav;
    uint8 sourceDecimals;
    uint256 navTolerance;
    bool shouldUnwrap;
    uint256 sourceAmount;  // NEW: Original amount before solver fees
}
```

Benefits:
- Exact NAV neutrality for Transfer operations
- Source adds +X, destination subtracts -X (solver fee absorbed by pool)
- Maintains current behavior for Sync operations

### 2. Canonical Token Restrictions (Alternative)
Restrict cross-chain operations to canonical tokens with known mappings:
- ETHEREUM_USDC ↔ BASE_USDC ↔ ARBITRUM_USDC
- Same for USDT, WETH, WBTC, native currencies
- Validate token decimals and ensure same canonical asset

Benefits:
- Predictable fee structures
- Better UX (only allow like-for-like transfers)
- Could enable more sophisticated fee handling

### 3. Operator Sync Mode (Future Enhancement)
Allow pool operators to perform sync operations with keeper fees:
- Operator can rebalance virtual balances
- Pay keeper fees from pool tokens, not user tokens
- Manual intervention for edge case resolution

## Implementation Considerations

### Message Enhancement Implementation
1. Update `DestinationMessage` struct
2. Modify `AIntents._processMessage()` to include source amount
3. Update `EAcrossHandler._handleTransferMode()` to use source amount for Transfer mode
4. Update all tests to use 7-field tuple encoding
5. Deploy new extension implementations

### Deployment Impact
- Requires new deployment of `AIntents` and `EAcrossHandler` 
- Old and new versions incompatible (different message formats)
- Coordinate deployment across all supported chains
- Update frontend to use new message encoding

## Mitigation (Current)

Until enhancement is implemented:
- Document expected NAV impact in user interfaces
- Consider solver fees as protocol cost for cross-chain functionality
- Monitor cumulative impact and consider periodic adjustments
- Ensure solver fee rates remain reasonable (typically < 1%)

## Related Files

- `contracts/protocol/extensions/adapters/AIntents.sol` - Source chain logic
- `contracts/protocol/extensions/EAcrossHandler.sol` - Destination chain logic  
- `contracts/protocol/types/Crosschain.sol` - Message structures
- `contracts/protocol/libraries/VirtualBalanceLib.sol` - Virtual balance management