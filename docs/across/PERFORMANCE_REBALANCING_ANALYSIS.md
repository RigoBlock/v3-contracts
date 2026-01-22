# Performance Rebalancing Analysis

## Implementation Status: COMPLETED ✅

The enhanced Sync mode with multiplier has been implemented. This document describes the problem, solution, and implementation details.

---

## Problem Statement

The current cross-chain implementation has a limitation when rebalancing performance between chains:

**Current Model Issue**: When using `OpType.Sync`, NAV is affected on BOTH chains:
- Source chain: NAV decreases (tokens sent)
- Destination chain: NAV increases (tokens received)

**What We Need**: Sync should ONLY affect NAV on the destination chain (the chain receiving the performance correction), not the source chain (which already has the correct price).

This document analyzes the scenarios, proposes solutions, and evaluates trade-offs.

---

## 1. Implementation Review

### Current Architecture Assessment

The implementation is **sound and well-designed** for the core use case (NAV-neutral transfers). Key strengths:

#### ✅ What Works Well

1. **Virtual Balance System (Base Token Denominated)**
   - Correctly fixes source chain NAV at transfer time
   - Performance follows physical custody (destination gets price movements)
   - Gas efficient (~5,800 gas savings vs token-denominated approach)

2. **Virtual Supply System**
   - Correctly tracks cross-chain share distribution
   - Handles zero-supply edge cases (DOS vulnerability fixed)
   - Proper interaction with virtual balances

3. **Transfer Mode (OpType.Transfer)**
   - NAV-neutral on both chains (as designed)
   - Bridge fees correctly reduce global NAV
   - Correct virtual balance/supply adjustments on both sides

4. **Security Model**
   - Stored NAV baseline prevents manipulation
   - Donation lock prevents reentrancy
   - Caller verification ensures only Across SpokePool triggers handler

#### ⚠️ Current Limitation: Sync Mode

**Sync Mode is currently incomplete for performance rebalancing:**

**Current Sync Behavior:**
```
Source (AIntents): validateNavImpact() only - no virtual adjustments
Destination (ECrosschain): No virtual adjustments - NAV increases naturally
```

**The Problem:**
- Source chain loses real tokens → NAV decreases
- Destination chain gains real tokens → NAV increases
- Both chains experience NAV change

**What We Actually Need for Performance Rebalancing:**
- Source chain: NAV should remain UNCHANGED (price is already correct)
- Destination chain: NAV should INCREASE (to correct the price)

---

## 2. Detailed Scenario Analysis

### Scenario A: Positive Performance (+200%) on Chain B

**Setup:**
- Pool A (Arbitrum): 0 tokens, virtualBalance = 1000 USDC (in base token), price = 1.0
- Pool B (Optimism): 2000 USDC (real), virtualSupply = 1000 shares, price = 2.0
- All tokens were originally transferred from A to B, where they appreciated

**Goal:** Sync performance from B to A (make A's price = 2.0)

**Current Model (BROKEN):**
```
Sync: B sends 2000 USDC to A

Source B:
  - Real: -2000 USDC
  - No virtual adjustments (Sync mode)
  - NAV: 0 (correct, but now no assets)

Destination A:
  - Real: +2000 USDC
  - No virtual adjustments (Sync mode)
  - Previous VB: +1000 USDC (base value)
  - NAV: (2000 real + 1000 VB) / supply = WRONG!
```

**Problem:** The virtualBalance on A doesn't get cleared, causing NAV miscalculation.

**What Should Happen:**
```
Sync: B sends 2000 USDC to A

Source B:
  - Real: -2000 USDC
  - Apply VB offset: +2000 USDC (in base)
  - NAV: unchanged (0 real + 2000 VB = 2000 effective)

Destination A:
  - Real: +2000 USDC
  - Clear VB: -1000 (removes old VB)
  - Mint virtual supply based on appreciation
  - NAV: 2.0 (correct!)
```

### Scenario B: Negative Performance (-60%) on Chain B

**Setup:**
- Pool A (Arbitrum): 0 tokens, virtualBalance = 1000 USDC (in base token), price = 1.0
- Pool B (Optimism): 400 USDC (real), virtualSupply = 400 shares, price = 0.4
- All tokens were originally transferred from A to B, where they depreciated

**Goal:** Correct A's price to 0.4 (currently A thinks it has 1000 USDC worth of value via VB)

**The Challenge:**
- A's VB says "+1000 USDC equivalent" but real value is only 400 USDC
- We need to reduce A's VB by 600 USDC equivalent to reflect the loss
- But A has NO real tokens to send!

**Current Model - Two-Step Workaround:**
```
Step 1: Transfer from B to A (moves tokens)
  - B sends 400 USDC to A
  - A: real = 400, VB reduces by 400, now VB = 600 (in base)
  - A's NAV: (400 real + 600 VB) / supply = 1000/supply = 1.0 (WRONG!)

Step 2: Sync from A to B (moves performance)
  - A sends 400 USDC to B
  - A: real = 0, VB = 600 (WRONG - no way to reduce this!)
```

**Problem:** The remaining VB of 600 cannot be reduced because A has no tokens!

---

## 3. Multiplier Modification Analysis

### Concept

Add a `multiplier` parameter to the intent message that adjusts virtual balance beyond the actual tokens transferred.

```solidity
struct SourceMessageParams {
    OpType opType;
    uint256 navTolerance;
    uint256 sourceNativeAmount;
    bool shouldUnwrapOnDestination;
    uint256 vbAdjustmentMultiplier; // NEW: 0-10000 (bps), default 10000 = 100%
}
```

### How It Would Work

**Source Chain (Sync with multiplier):**
```solidity
// Calculate VB adjustment based on multiplier
uint256 actualTransferValue = outputValueInBase;
uint256 adjustedValue = (actualTransferValue * vbAdjustmentMultiplier) / 10000;

// Write VB for the full intended correction, not just transferred amount
baseToken.updateVirtualBalance(adjustedValue.toInt256());
```

**Destination Chain (Sync with multiplier):**
```solidity
// If multiplier < 100%, adjust virtual supply by remaining portion
uint256 remainingRatio = 10000 - vbAdjustmentMultiplier;
// ... handle proportionally
```

### Analysis

#### Pros
1. **Enables Full Price Correction**: Can correct prices even when tokens < VB
2. **Single Transaction**: No need for complex multi-step flows
3. **Flexible**: Works for any depreciation level

#### Cons
1. **Complexity**: Adds non-trivial logic to both source and destination
2. **Attack Surface**: Malicious operator could set wrong multiplier
3. **Conceptual Confusion**: "Multiplier" is not intuitive
4. **Coordination Problem**: Source multiplier must match destination expectation

#### Verdict: **Feasible but complex**

The multiplier approach works mathematically but introduces coordination complexity. The source and destination must agree on the multiplier's meaning and handling.

---

## 4. Manual VB Adjustment Analysis

### Concept

Allow pool operator to manually reduce virtual balance (up to 100% of current VB) without transferring tokens.

```solidity
function adjustVirtualBalance(
    address token,
    int256 reduction  // Must be negative, capped at current VB
) external onlyPoolOperator {
    int256 currentVB = getVirtualBalance(token);
    require(reduction <= 0, "Can only reduce");
    require(reduction >= -currentVB, "Cannot reduce below zero");
    
    updateVirtualBalance(token, reduction);
}
```

### Why This Is Safe (For VB Reduction Only)

**Reducing VB = Reducing NAV = Operator takes a loss**

```
Example: Pool A has VB = +1000 USDC, real = 0, supply = 1000
NAV = (0 + 1000) / 1000 = 1.0

Operator reduces VB by 600:
NAV = (0 + 400) / 1000 = 0.4

Result: All holders' shares are worth 40% less
```

**Who loses?** All holders (including operator if they hold shares)
**Who gains?** Nobody - this is value destruction, not transfer

This is the **same outcome** as if the tokens had depreciated - the operator is just acknowledging reality.

### Why Allowing VB Increase Would Be Dangerous

**Increasing VB = Increasing NAV = Artificial price inflation**

```
Example: Pool A has VB = 0, real = 1000, supply = 1000
NAV = 1000 / 1000 = 1.0

Malicious operator increases VB by 1000:
NAV = (1000 + 1000) / 1000 = 2.0

Result: NAV doubled without any real value
```

**Attack Vector:**
1. Operator inflates VB
2. New investors buy at inflated 2.0 NAV
3. Operator redeems at inflated price
4. NAV crashes when VB cleared, new investors lose

**This is why we MUST NOT allow VB increases.**

### Virtual Supply Considerations

**Can operator reduce virtual supply?**

```
Reducing VS = More shares for remaining supply = Higher NAV
```

This is **equivalent to burning shares** - the operator would be destroying value that represents real tokens on other chains. This should NOT be allowed unilaterally.

**Can operator increase virtual supply?**

```
Increasing VS = Fewer shares for remaining supply = Lower NAV
```

This is similar to minting new shares - it dilutes existing holders. Could be used for legitimate rebalancing but has abuse potential.

### Recommendation: Allow VB Reduction Only

```solidity
/// @notice Allows operator to reduce virtual balance, acknowledging cross-chain losses
/// @dev Only reductions allowed (never increases) - prevents price manipulation
/// @param token The token whose virtual balance to reduce
/// @param reduction The amount to reduce (must be negative)
function acknowledgeVirtualBalanceLoss(
    address token,
    int256 reduction
) external onlyPoolOperator {
    require(reduction < 0, "Must be negative");
    int256 currentVB = getVirtualBalance(token);
    require(currentVB > 0, "No positive VB to reduce");
    require(-reduction <= currentVB, "Cannot reduce below zero");
    
    updateVirtualBalance(token, reduction);
    emit VirtualBalanceLossAcknowledged(token, reduction, currentVB + reduction);
}
```

---

## 5. Proposed Modified Sync Specification

### New OpType: SyncFromSource

The key insight is that Sync needs **asymmetric behavior**:
- **Source** should maintain NAV (apply virtual offset)
- **Destination** should change NAV (receive performance)

### Current Flow vs Proposed Flow

**Current Sync (BROKEN for performance rebalancing):**
```
Source: No virtual adjustment → NAV decreases
Destination: No virtual adjustment → NAV increases
Result: Both NAVs change (wrong)
```

**Proposed Sync (FIXED):**
```
Source: Apply virtual balance offset → NAV unchanged
Destination: Reduce/clear source VB, adjust VS → NAV corrected

OR (for negative performance):

Source: Apply partial VB offset based on multiplier → NAV unchanged  
Destination: Accept tokens + clear remaining VB on source via callback
```

### Detailed Specification

#### For Positive Performance (Destination Has Gains)

**Goal:** Transfer gains from destination to source without moving all tokens

**Option A: Transfer All, Keep What You Need**
```
1. Transfer ALL from destination to source (Transfer mode)
2. Transfer back what destination needs (Transfer mode)
```
This is the simplest but requires two transactions and extra bridge fees.

**Option B: Enhanced Sync with VB Write on Source**

Modify Sync behavior:
```solidity
// In AIntents._handleSourceSync():
if (sourceParams.opType == OpType.Sync) {
    // Sync mode: Write VB to maintain NAV on source
    // This "locks in" the source NAV at current level
    baseToken.updateVirtualBalance(outputValueInBase.toInt256());
}
```

```solidity
// In ECrosschain._handleSyncMode():
// Clear any incoming VB from source
int256 sourceVB = baseToken.getVirtualBalance();
if (sourceVB > 0) {
    // Reduce by received amount
    baseToken.updateVirtualBalance(-min(amount, sourceVB));
}
// Remaining value increases local NAV (performance received)
```

#### For Negative Performance (Destination Has Losses)

**The Challenge:** Source has VB > actual tokens on destination

**Solution A: Manual VB Reduction on Source**
```
1. Operator calls acknowledgeVirtualBalanceLoss(token, -lossAmount) on source
2. Source NAV correctly reduced
3. No cross-chain transaction needed
```

**Solution B: Sync with Multiplier**
```solidity
struct SourceMessageParams {
    ...
    uint256 vbMultiplier; // bps, e.g., 2500 = 250% (for 40% remaining value)
}

// Source: Write VB for actual transfer + additional multiplied amount
// Result: VB covers the "gap" between actual tokens and original VB
```

**Solution C: Two-Step with Acknowledgment**
```
1. Transfer remaining tokens from destination to source
2. Operator acknowledges remaining loss via manual reduction
```

---

## 6. Recommended Implementation Path

### Phase 1: Manual VB Reduction (Immediate)

**Add to ECrosschain or new extension:**
```solidity
function acknowledgeVirtualBalanceLoss(
    address token,
    uint256 reductionAmount  // Amount to reduce (positive value)
) external;
```

**Benefits:**
- Simple to implement
- No cross-chain complexity
- Operator can correct prices without moving tokens
- Only allows value reduction (safe)

### Phase 2: Enhanced Sync Mode (Medium Term)

**Modify Sync behavior:**

**Source Chain:**
```solidity
if (opType == OpType.Sync) {
    // Write VB to maintain source NAV (transfer leaves NAV unchanged)
    baseToken.updateVirtualBalance(outputValueInBase.toInt256());
}
```

**Destination Chain:**
```solidity
if (opType == OpType.Sync) {
    // First reduce any existing positive VB
    // Then if tokens > VB cleared, remaining increases local NAV
    _handleSyncWithVBClearing(token, amount);
}
```

### Phase 3: Multiplier (Optional, If Needed)

Only implement if Phase 1 and 2 prove insufficient:
- Complex scenarios requiring precise cross-chain coordination
- Avoiding multiple transactions for edge cases

---

## 7. Security Considerations

### Manual VB Reduction Risks

| Risk | Mitigation |
|------|------------|
| Operator reduces VB maliciously | Only reduction allowed - hurts operator too |
| Front-running | No MEV opportunity (reduces value for everyone) |
| Incorrect reduction | Operator responsibility - reversible via Sync |

### Enhanced Sync Risks

| Risk | Mitigation |
|------|------------|
| VB desync between chains | Use deterministic calculations |
| NAV manipulation during Sync | Stored NAV baseline (existing) |
| Wrong OpType selection | Document clearly, UI guardrails |

### Multiplier Risks

| Risk | Mitigation |
|------|------------|
| Wrong multiplier value | Validation bounds (0-10000 bps) |
| Coordination failure | Single source of truth for multiplier |
| Complexity bugs | Extensive testing required |

---

## 8. Summary Recommendations

### Opinion on Current Implementation
**Grade: B+** - Well-designed for core use case, needs enhancement for performance rebalancing

### Opinion on Multiplier Approach
**Grade: B-** - Mathematically sound but introduces complexity and coordination challenges. Consider as Phase 3 if simpler approaches insufficient.

### Opinion on Manual VB Adjustment
**Grade: A** - Simple, safe (reduction only), and solves the negative performance case. Strongly recommended for Phase 1.

### Downside of Allowing Price Inflation
If operator could increase VB or decrease VS:
1. **Ponzi Attack**: Inflate NAV → attract new investors → redeem at high price → crash
2. **Loss of Trust**: Breaks core promise of fair NAV calculation
3. **Regulatory Risk**: Manipulation of fund pricing is illegal in many jurisdictions

**Recommendation: NEVER allow unilateral NAV increases by operator**

### Proposed Roadmap

1. **Phase 1** (Now): Implement `acknowledgeVirtualBalanceLoss()` for manual VB reduction
2. **Phase 2** (Next): Modify Sync to write VB on source and clear on destination
3. **Phase 3** (If Needed): Add multiplier for complex edge cases

---

## Implementation Details (COMPLETED)

### Changes Made

#### 1. Updated `SourceMessageParams` struct
Added `syncMultiplier` field (0-10000 bps):
- 0 = legacy behavior (no VB offset on source, no VB clearing on destination)
- 10000 = full NAV neutralization on source, full VB clearing on destination

#### 2. Updated `DestinationMessageParams` struct
Added `syncMultiplier` field to pass the multiplier from source to destination.

#### 3. AIntents._handleSourceSync() - NEW METHOD
When `OpType.Sync` with multiplier > 0:
```solidity
// Neutralize syncMultiplier% of the transfer via VB offset
uint256 neutralizedAmount = (outputValueInBase * syncMultiplier) / 10000;
baseToken.updateVirtualBalance(neutralizedAmount.toInt256());
```

#### 4. ECrosschain._handleSyncMode() - NEW METHOD
When `OpType.Sync` with multiplier > 0:
```solidity
// Calculate neutralized amount (same as source)
uint256 neutralizedAmount = (amountInBase * syncMultiplier) / 10000;

// Clear positive VB up to neutralized amount
if (currentVB > 0 && neutralizedAmount > 0) {
    uint256 vbToClear = min(neutralizedAmount, currentVB);
    baseToken.updateVirtualBalance(-vbToClear.toInt256());
}
```

### Usage Examples

**Positive Performance (+200% on Chain B):**
```
Pool A: VB = +1000, real = 0, price = 1.0
Pool B: VS = 1000, real = 2000, price = 2.0

Sync from B to A with 100% multiplier:
- B: writes VB = +2000, NAV unchanged at 2.0
- A: clears VB (1000), receives 2000 real, NAV = 2.0 ✓
```

**Partial Sync (50% multiplier):**
```
Sync from B to A with 50% multiplier:
- B: writes VB = +1000 (50% neutralized), NAV decreases by 50% of transfer
- A: clears VB up to 1000, remaining value increases NAV
```

**Negative Performance (-60% on Chain B):**
```
Pool A: VB = +1000, real = 0, price = 1.0
Pool B: VS = 1000, real = 400, price = 0.4

Sync alone cannot fully correct (400 < 1000 VB).
Requires: Transfer 400 from B to A, then manual VB reduction for remaining 600.
```

### Files Modified
- `contracts/protocol/types/Crosschain.sol` - Added syncMultiplier to both structs
- `contracts/protocol/extensions/adapters/AIntents.sol` - Added _handleSourceSync()
- `contracts/protocol/extensions/ECrosschain.sol` - Added _handleSyncMode()
- `test/extensions/ECrosschainUnit.t.sol` - Added 3 new tests
- Various test files - Updated struct constructors

---

## Appendix: Mathematical Proofs

### Proof: VB Reduction Cannot Create Value

Let:
- `NAV = (realValue + VB) / supply`
- Operator reduces VB by `x`

New NAV: `(realValue + VB - x) / supply`

Since `x > 0` and supply unchanged:
- New NAV < Old NAV
- Total pool value decreased
- No holder benefits (including operator)

∴ VB reduction is value-destructive, not exploitable ✓

### Proof: VB Increase Creates Artificial Value

Let:
- `NAV = (realValue + VB) / supply`
- Operator increases VB by `x`

New NAV: `(realValue + VB + x) / supply`

Since `x > 0`:
- New NAV > Old NAV (artificial)
- Operator can redeem at inflated price
- After redemption, remaining holders suffer dilution

∴ VB increase is exploitable, must be prevented ✓
