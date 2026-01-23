# Performance Attribution & Rebalancing (VS-Only Model)

## Overview

The Rigoblock cross-chain system uses **Virtual Supply (VS) only** to maintain NAV integrity during cross-chain transfers. This document explains:
1. How performance is attributed across chains
2. How to rebalance performance when needed

## Core Principle

**Performance is shared proportionally**: Both source and destination chains share trading gains/losses based on their effective supply ratios.

## Virtual Supply Model

### Key Formulas

```
Effective Supply = Total Supply + Virtual Supply

Where:
- Virtual Supply < 0 on source (shares sent to other chains)
- Virtual Supply > 0 on destination (shares received from other chains)

NAV = Total Pool Value / Effective Supply
```

### Transfer Flow Example

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

---

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

---

## Transfer vs Sync Modes

### Transfer Mode (OpType.Transfer) - NAV Neutral

**Behavior:**
- Source: Writes **negative VS** (shares leaving)
- Destination: Writes **positive VS** (shares arriving)
- Both chains: NAV unchanged

**Use for:**
- Moving liquidity between chains
- NAV-neutral token movement

### Sync Mode (OpType.Sync) - NAV Changes

**Behavior:**
- Source: No VS adjustment → NAV decreases (tokens leave)
- Destination: No VS adjustment → NAV increases (tokens arrive)
- Both chains: NAV changes naturally

**Use for:**
- Performance rebalancing
- Donations
- Intentional NAV adjustments

---

## Rebalancing Scenarios

### Scenario A: Equalizing Chain NAVs

**Situation:**
- Chain A: NAV = 1.0, low activity
- Chain B: NAV = 1.2, high trading gains

**Goal:** Share performance from B to A

**Solution:** Use Sync mode
```
1. Initiate Sync transfer from B to A
2. B sends tokens (NAV decreases from 1.2)
3. A receives tokens (NAV increases from 1.0)
4. NAVs converge toward equilibrium
```

### Scenario B: Emergency Liquidity

**Situation:**
- Chain A: Needs liquidity, NAV = 1.0
- Chain B: Excess liquidity, NAV = 1.0

**Goal:** Move liquidity without NAV impact

**Solution:** Use Transfer mode
```
1. Initiate Transfer from B to A
2. B writes negative VS (effective supply decreases)
3. A writes positive VS (effective supply increases)
4. Both NAVs remain at 1.0
```

### Scenario C: Consolidating Assets

**Situation:**
- Pool has assets scattered across 5 chains
- Want to consolidate on one chain

**Solution:** Sequential Transfers
```
For each source chain:
1. Transfer tokens to destination (Transfer mode)
2. Source ends with negative VS
3. Destination accumulates positive VS

Note: Effective supply constraint limits single transfer to 87.5% of effective supply
```

---

## Safety Constraints

### Effective Supply Buffer (1/MINIMUM_SUPPLY_RATIO)

**Rule:** Cannot transfer more than 87.5% of effective supply in a single Transfer.

```solidity
// NavImpactLib.validateSupply()
// MINIMUM_SUPPLY_RATIO = 8 (12.5%)
int256 effectiveSupply = int256(totalSupply) + virtualSupply - sharesLeaving;
require(effectiveSupply >= int256(totalSupply / MINIMUM_SUPPLY_RATIO), EffectiveSupplyTooLow());
```

**Why:** Ensures pool remains functional with positive effective supply.

### Post-Burn Protection

**Rule:** Burns cannot push effective supply below 12.5% threshold.

```solidity
// MixinActions._burn()
int256 virtualSupply = VirtualStorageLib.getVirtualSupply();
if (virtualSupply < 0) {
    int256 effectiveSupply = int256(newTotalSupply) + virtualSupply;
    require(effectiveSupply >= int256(newTotalSupply / MINIMUM_SUPPLY_RATIO), EffectiveSupplyTooLowAfterBurn());
}
```

**Why:** Prevents bypassing the constraint via sequential burns.

### Workaround for Full Consolidation

1. Transfer 80%
2. Users burn shares, reducing total supply
3. Transfer remaining 80% of new effective supply
4. Repeat until consolidated

---

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

---

## Summary

The **VS-only model** provides:
- ✅ Simpler implementation (single storage per chain)
- ✅ Proportional performance attribution by default
- ✅ Lower gas costs (1 SSTORE per side)
- ✅ No synchronization complexity
- ✅ 12.5% safety buffer prevents supply exhaustion
- ✅ Post-burn protection prevents constraint bypass
- ✅ Clear distinction between Transfer (NAV-neutral) and Sync (NAV-impacting)
