# Virtual Supply & Virtual Balance System Analysis

## Overview
The Rigoblock v3 protocol uses a dual system of **virtual supply** and **virtual balances** to maintain NAV integrity during cross-chain transfers. This document analyzes the current implementation, identifies issues, and proposes fixes.

## The Problem Being Solved

When tokens are bridged cross-chain:
1. **Source chain**: Pool loses tokens (negative NAV impact)
2. **Destination chain**: Pool gains tokens (positive NAV impact)
3. **Bridge fees**: Real cost (inputAmount - outputAmount) that should reduce NAV
4. **Challenge**: Maintain NAV neutrality while tracking true economic position

## Current System Design

### Virtual Supply
- **Purpose**: Represents pool tokens that exist on other chains
- **Units**: Denominated in pool token units (shares)
- **When used**: When totalSupply exists on a chain but tokens are leaving

### Virtual Balances
- **Purpose**: Offsets physical token balance changes to maintain NAV neutrality
- **Units**: Denominated in the specific token's units
- **When used**: When tokens are transferred between chains

## Critical Issues Identified

### 1. AIntents `_handleSourceTransfer` Logic Flaws

**Current approach:**
```solidity
if (virtualSupply > 0) {
    // Burn virtual supply proportionally
    uint256 supplyToBurn = (transferValue * virtualSupply) / totalPoolValue;
    // Then handle remainder with virtual balance
}
```

**Problems:**
- Uses `inputAmount` to calculate burn amount, but bridge fees mean actual value transferred is less
- The "uncompensated amount" calculation is convoluted and mixes units incorrectly
- Doesn't clearly account for bridge fee impact on NAV

**What should happen:**
- Bridge fee (inputAmount - outputAmount scaled) should REDUCE NAV (it's a real cost)
- Virtual adjustments should make transfer NAV-neutral BEFORE applying fee impact
- Or: Make adjustments NAV-neutral AFTER accepting the expected fee delta

### 2. NavImpactLib Doesn't Account for Virtual Supply

**Issue in `validateNavImpactTolerance`:**
```solidity
// Calculate total assets value: NAV × totalSupply
uint256 totalAssetsValue = poolTokens.unitaryValue * poolTokens.totalSupply / (10 ** poolDecimals);
```

**Problem**: Ignores virtual supply, which represents real economic value on other chains

**Should be:**
```solidity
uint256 effectiveSupply = poolTokens.totalSupply + VirtualBalanceLib.getVirtualSupply().toUint256();
uint256 totalAssetsValue = poolTokens.unitaryValue * effectiveSupply / (10 ** poolDecimals);
```

### 3. EAcrossHandler Virtual Supply Calculation

**Current:**
```solidity
// Convert base value to pool shares (virtual supply represents pool tokens)
uint256 virtualSupplyIncrease = (baseValue * (10 ** poolDecimals)) / currentNav;
```

**This is correct** - proper decimal scaling to pool token units

**However**, should also account for any positive virtual balance that gets reduced first

### 4. Code Duplication Between AIntents and NavImpactLib

Both calculate similar things:
- Convert token amounts to base value
- Calculate proportional impacts
- Determine NAV changes

**Solution**: Refactor common logic into NavImpactLib

## Conceptual Issues with Mixed System

### The Good ✅
1. **Flexible**: Handles edge cases where supply exists on one chain but not another
2. **Correct accounting**: Virtual supply tracks cross-chain ownership correctly
3. **NAV protection**: Virtual balances offset unwanted NAV changes from transfers

### The Bad ⚠️
1. **Complex**: Two systems with different units (shares vs tokens) is confusing
2. **Priority ambiguity**: "Handle virtual supply first, then virtual balance" - why this order?
3. **Incomplete**: NavImpactLib doesn't account for virtual supply

### The Ugly 🐛
1. **Unit mixing**: Calculations mix base token units, input token units, and share units
2. **Bridge fee handling**: Unclear where/how bridge fees impact NAV
3. **Edge case interactions**: What if both systems have positive values? Current logic may double-adjust

## Proposed Solutions

### Option A: NAV-Neutral First, Then Apply Fee
```solidity
// 1. Calculate bridge fee impact
uint256 inputInBase = convertToBaseValue(inputToken, inputAmount);
uint256 outputInBase = convertToBaseValue(outputToken, scaledOutputAmount);
uint256 bridgeFeeInBase = inputInBase - outputInBase; // Real cost

// 2. Make transfer NAV-neutral (for outputAmount, not inputAmount)
// This means: offset the outputAmount that's leaving
if (virtualSupply > 0) {
    uint256 outputValueInBase = convertToBaseValue(outputToken, scaledOutputAmount);
    uint256 supplyToBurn = (outputValueInBase * virtualSupply) / totalPoolValue;
    // Burn up to virtualSupply
    actualBurn = min(supplyToBurn, virtualSupply);
    
    // If didn't burn enough, use virtual balance for remainder
    if (actualBurn < supplyToBurn) {
        uint256 uncompensatedValue = outputValueInBase - (actualBurn * totalPoolValue / virtualSupply);
        uint256 uncompensatedTokens = (uncompensatedValue * scaledOutputAmount) / outputValueInBase;
        adjustVirtualBalance(inputToken, uncompensatedTokens);
    }
} else {
    // Pure virtual balance approach
    adjustVirtualBalance(inputToken, scaledOutputAmount);
}

// 3. Bridge fee automatically reduces NAV (no offsetting adjustment)
// inputAmount was sent, outputAmount arrives (scaled), difference is fee
```

### Option B: Accept Expected Delta
```solidity
// Calculate expected NAV delta from bridge fee
uint256 bridgeFeeInBase = inputInBase - outputInBase;
uint256 expectedNavDecrease = (bridgeFeeInBase * 10**poolDecimals) / effectiveSupply;

// Make full transfer NAV-neutral (using inputAmount)
// ... virtual adjustments ...

// Validate final NAV is: initialNav - expectedNavDecrease
// with small tolerance for rounding
```

## Recommendations

### Immediate Fixes

1. **Fix NavImpactLib** to include virtual supply in calculations
2. **Refactor AIntents** to use NavImpactLib for conversions and calculations
3. **Clarify bridge fee handling**: Choose Option A or B above and implement consistently
4. **Add unit tests** that verify:
   - Bridge fees correctly reduce NAV
   - Virtual supply is included in NAV impact calculations
   - Round-trip transfers (A→B→A) end with correct NAV (minus 2x bridge fees)

### Long-term Improvements

1. **Consolidate systems**: Consider if virtual balances alone could handle all cases
2. **Better documentation**: Clear flowcharts showing when each system activates
3. **Unit consistency**: Helper functions to clearly convert between token units and share units
4. **Add events**: Emit events when virtual supply/balances change for transparency

## Edge Cases to Test

1. **All supply on source**: totalSupply > 0, virtualSupply = 0
2. **All supply on destination**: totalSupply = 0, virtualSupply > 0
3. **Mixed supply**: totalSupply > 0, virtualSupply > 0
4. **Multiple chains**: Supply spread across 3+ chains
5. **Round-trip**: A→B→A should equal 2x bridge fee cost
6. **Empty pool**: totalSupply = 0, virtualSupply = 0
7. **BSC decimal conversion**: 18 decimal USDC → 6 decimal USDC

## Conclusion

The current implementation has the right ideas but:
- Mixes units inconsistently
- Doesn't clearly handle bridge fees
- Has code duplication
- Missing virtual supply in NavImpactLib

The fixes should focus on:
1. Clear unit conversions
2. Explicit bridge fee accounting
3. Code reuse via NavImpactLib
4. Comprehensive testing of edge cases
