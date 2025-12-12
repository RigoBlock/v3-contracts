# Stack Depth Issue Resolution

## Problem

The AIntents.depositV3() function hits Solidity's stack-too-deep error because it needs to:
1. Accept 12 parameters (matching Across depositV3 interface)
2. Process those parameters internally
3. Call Across depositV3 with those 12 parameters

This exceeds Solidity's 16 local variable limit when including internal processing variables.

## Attempted Solutions

### 1. Inline Functions ✗
Tried inlining `_processMessage()` and `_handleTokenPreparation()` - still hits stack limit.

### 2. Scoped Blocks ✗
Tried using scoped blocks `{}` to limit variable lifetime - still hits stack limit.

### 3. Separate Helper Functions ✗
Extracting logic into helpers doesn't solve the root issue - the 12 parameters still exist in the main function.

## Root Cause

The issue is the Across depositV3 signature itself has 12 parameters. When combined with:
- Reent rancy guard state
- Processing variables  
- ABI encoding
- Virtual balance calculations

We exceed the stack limit.

## Recommended Solutions

### Option A: Use Struct Parameter (Recommended)
Instead of 12 individual parameters, accept a single struct:

```solidity
struct DepositParams {
    address depositor;
    address recipient;
    address inputToken;
    address outputToken;
    uint256 inputAmount;
    uint256 outputAmount;
    uint256 destinationChainId;
    address exclusiveRelayer;
    uint32 quoteTimestamp;
    uint32 fillDeadline;
    uint32 exclusivityDeadline;
    bytes message;
}

function depositV3(DepositParams calldata params) external payable;
```

This reduces stack usage significantly while maintaining all functionality.

**Tradeoff**: Signature differs from Across, but this is acceptable per your comment: "the transaction will have to be created in a different format than the across call, so it's acceptable if it helps us reach the goal"

### Option B: Use Via-IR Compilation
Keep current signature but compile with `--via-ir` flag.

**Tradeoff**: Longer compilation time, slightly different gas costs.

### Option C: Use Assembly for Call
Manually encode and call Across using assembly, avoiding Solidity stack limitations.

**Tradeoff**: More complex, harder to maintain, higher risk of bugs.

## Recommendation

**Use Option A** - struct parameter approach. It:
- Solves the stack depth issue completely
- Maintains all functionality
- Is easier to use (single parameter vs 12)
- Has better gas efficiency
- Aligns with your stated acceptance of different transaction format

The client/frontend would encode the struct when calling, which is straightforward.

## Implementation Status

Current code uses 12-parameter signature and fails compilation. Need to switch to struct approach to proceed with:
- Fixing remaining logical issues
- Adding proper error handling  
- Updating tests
- Adding override keywords
- Fixing compilation warnings
