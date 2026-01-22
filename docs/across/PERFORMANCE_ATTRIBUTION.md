# Performance Attribution Model (VS-Only)

## Overview

The Rigoblock cross-chain system uses **Virtual Supply (VS) only** to maintain NAV integrity during cross-chain transfers. This document explains how performance is attributed with this simplified model.

## Core Principle

**Performance is shared proportionally**: Both source and destination chains share trading gains/losses based on their effective supply ratios.

## How It Works

### Virtual Supply Model

**Key Formula:**
```
Effective Supply = Total Supply + Virtual Supply

Where:
- Virtual Supply < 0 on source (shares sent to other chains)
- Virtual Supply > 0 on destination (shares received from other chains)
```

**NAV Calculation:**
```
NAV = Total Pool Value / Effective Supply
```

### Transfer Flow

**Setup:**
- Pool A on Arbitrum (source chain)
- Pool B on Optimism (destination chain)
- Transfer 1000 USDC from A to B
- USDC price: $1.00, NAV: $1.00, Total Supply: 10,000 shares

**Source Chain (Arbitrum) - AIntents:**
```
Before Transfer:
  Real Balance: 10,000 USDC
  Virtual Supply: 0
  Effective Supply: 10,000 shares
  NAV: $10,000 / 10,000 = $1.00

After Transfer:
  Real Balance: 9,000 USDC (sent 1000)
  Virtual Supply: -1,000 shares (outputValue / NAV)
  Effective Supply: 10,000 + (-1,000) = 9,000 shares
  NAV: $9,000 / 9,000 = $1.00 ✓ (unchanged)
```

**Destination Chain (Optimism) - ECrosschain:**
```
Before Transfer:
  Real Balance: 5,000 USDC
  Virtual Supply: 0
  Effective Supply: 5,000 shares
  NAV: $5,000 / 5,000 = $1.00

After Transfer:
  Real Balance: 5,980 USDC (received 980 after fees)
  Virtual Supply: +980 shares (receivedValue / NAV)
  Effective Supply: 5,000 + 980 = 5,980 shares
  NAV: $5,980 / 5,980 = $1.00 ✓ (unchanged)
```

## Performance Attribution Scenarios

### Scenario 1: Trading Gains on Destination

**Destination generates 500 USDC yield from trading:**

```
Destination Pool State:
  Real: 6,480 USDC
  Virtual Supply: +980 shares
  Effective Supply: 5,980 shares
  Total Value: $6,480
  NAV: $6,480 / 5,980 = $1.084

Performance Attribution:
  Total Gain: $500
  Local holders: (5,000 / 5,980) × $500 = $418
  Virtual holders: (980 / 5,980) × $500 = $82
```

**Result:** Gains split proportionally by effective supply ✅

### Scenario 2: Price Appreciation

**USDC appreciates to $1.10:**

```
Source Chain:
  Real: 9,000 USDC × $1.10 = $9,900
  Virtual Supply: -1,000 shares
  Effective Supply: 9,000 shares
  NAV: $9,900 / 9,000 = $1.10 ✓

Destination Chain:
  Real: 5,980 USDC × $1.10 = $6,578
  Virtual Supply: +980 shares
  Effective Supply: 5,980 shares
  NAV: $6,578 / 5,980 = $1.10 ✓
```

**Result:** Both chains see proportional NAV increase ✅

### Scenario 3: Price Depreciation

**USDC depreciates to $0.90:**

```
Source Chain:
  Real: 9,000 USDC × $0.90 = $8,100
  Virtual Supply: -1,000 shares
  Effective Supply: 9,000 shares
  NAV: $8,100 / 9,000 = $0.90

Destination Chain:
  Real: 5,980 USDC × $0.90 = $5,382
  Virtual Supply: +980 shares
  Effective Supply: 5,980 shares
  NAV: $5,382 / 5,980 = $0.90
```

**Result:** Both chains see proportional NAV decrease ✅

## Safety Constraints

### 10% Effective Supply Buffer

**Rule:** Negative VS cannot exceed 90% of total supply.

```solidity
// In NavImpactLib.validateNavImpact()
int256 effectiveSupply = int256(totalSupply) + virtualSupply - sharesLeaving;
require(effectiveSupply >= int256(totalSupply / 10), EffectiveSupplyTooLow());
```

**Why:** Prevents supply exhaustion and ensures pool remains operational.

### Post-Burn Protection

**Rule:** Burns cannot push effective supply below 10% threshold.

```solidity
// In MixinActions._burn()
int256 virtualSupply = VirtualStorageLib.getVirtualSupply();
if (virtualSupply < 0) {
    int256 effectiveSupply = int256(newTotalSupply) + virtualSupply;
    require(effectiveSupply >= int256(newTotalSupply / 10), EffectiveSupplyTooLowAfterBurn());
}
```

**Why:** Prevents bypassing the 10% constraint via sequential burns.

## Comparison with Previous VB+VS Model

| Aspect | VS-Only (Current) | VB+VS (Previous) |
|--------|-------------------|------------------|
| **Storage writes** | 1 per side (VS only) | 2 per side (VB + VS) |
| **Performance attribution** | Shared proportionally | Destination gets price movements |
| **Complexity** | Simpler | More complex |
| **Rebalancing** | Always 1-step | 2-step in edge cases |
| **Gas cost** | Lower | Higher |
| **Synchronization** | None needed | VB must sync with VS |

## Mathematical Verification

### NAV Invariant (Transfer Mode)

For transfers to be NAV-neutral:
```
NAV_before = NAV_after

Where:
  NAV = TotalValue / EffectiveSupply
  EffectiveSupply = TotalSupply + VirtualSupply
```

**Proof:**
```
Before: NAV = V / S
After:  NAV = (V - ΔV) / (S + (-ΔV/NAV))
           = (V - ΔV) / (S - ΔV/NAV)
           = (V - ΔV) / ((S×NAV - ΔV) / NAV)
           = (V - ΔV) × NAV / (S×NAV - ΔV)
           = (V - ΔV) × NAV / (V - ΔV)
           = NAV ✓
```

### Effective Supply Constraint

```
VS_min = -0.9 × TotalSupply
EffectiveSupply_min = TotalSupply + VS_min = 0.1 × TotalSupply
```

This ensures at least 10% of supply remains for pool operations.

## Sync Mode

**Sync mode (OpType.Sync)** allows NAV changes:
- No VS adjustments on either chain
- NAV impacts both chains naturally
- Used for: donations, performance rebalancing, gas refunds

```
Source: Tokens leave → NAV decreases
Destination: Tokens arrive → NAV increases
```

## Conclusion

The **VS-only model** provides:
- ✅ Simpler implementation (single storage per chain)
- ✅ Proportional performance attribution
- ✅ Lower gas costs
- ✅ No synchronization complexity
- ✅ 10% safety buffer prevents supply exhaustion
- ✅ Post-burn protection prevents constraint bypass
