# Performance Attribution Model

## Overview

The Rigoblock cross-chain system uses **base token denominated virtual balances** to achieve correct performance attribution between chains. This document explains how performance is attributed and why this approach was chosen.

## Core Principle

**Performance follows physical custody**: The chain holding the real tokens gets the price performance attribution.

## How It Works

### Transfer Flow

**Setup:**
- Pool A on Arbitrum (base token: ETH)
- Transfers 1000 USDC to Pool B on Optimism
- USDC price at transfer: $1.00
- ETH price: $2000

**Source Chain (Arbitrum):**
```
Real Balance: -1000 USDC (sent via bridge)
Virtual Balance: +0.5 ETH (base token units)
  
Calculation:
  1000 USDC @ $1.00 = $1000
  $1000 / $2000 per ETH = 0.5 ETH
  Store: ETH virtual balance = +0.5 ETH (FIXED)

NAV Impact: 0 (transfer is NAV-neutral)
```

**Destination Chain (Optimism):**
```
Real Balance: +980 USDC (after bridge fees)
Virtual Supply: +0.49 ETH worth of shares

Calculation:
  980 USDC @ $1.00 = $980
  $980 / NAV = X shares
  Store: Virtual Supply = X shares (FIXED in share units)

NAV Impact: ~0 (transfer is NAV-neutral)
```

### Price Movement Scenarios

#### Scenario 1: USDC Appreciates to $1.10

**Source Chain (Arbitrum):**
```
NAV Calculation:
  Real: 0 USDC (all transferred)
  Virtual: +0.5 ETH = +0.5 ETH (unchanged!)
  
NAV Change: 0 (base token VB is FIXED)
```

**Destination Chain (Optimism):**
```
NAV Calculation:
  Real: 980 USDC × $1.10 = $1,078
  Virtual Supply: -0.49 ETH (unchanged)
  
NAV Change: +$98 increase
```

**Result:** Destination gets all the appreciation ✅

#### Scenario 2: USDC Depreciates to $0.90

**Source Chain (Arbitrum):**
```
NAV Change: 0 (base token VB is FIXED)
```

**Destination Chain (Optimism):**
```
NAV Calculation:
  Real: 980 USDC × $0.90 = $882
  Virtual Supply: -0.49 ETH (unchanged)
  
NAV Change: -$98 decrease
```

**Result:** Destination takes all the loss, source avoids it ✅

#### Scenario 3: Trading Gains (Constant Price)

**Destination generates 500 USDC yield from trading (USDC price constant at $1.00):**

```
Destination NAV:
  Real: 1480 USDC × $1.00 = $1,480
  Virtual Supply: -0.49 ETH = -$980
  Net contribution: $500
  
Split pro-rata:
  Local holders: (supply / (supply + VS)) × $500
  Virtual holders: (VS / (supply + VS)) × $500
```

**Result:** Gains split fairly between chains via virtual supply ✅

## Why Base Token Units?

### Alternative: Token Unit Virtual Balances (Not Implemented)

**If we stored VB in token units (1000 USDC):**

**When USDC appreciates to $1.10:**
- Source VB: 1000 USDC × $1.10 = $1,100 → NAV increases by $100
- Destination: Neutralized via offsetting entries → NAV constant

**Result:** Source gets performance, but source doesn't hold the tokens!

**Problem:** Cannot rebalance when source has no tokens:
- To sync gains from source → destination: Need to transfer from source
- But source has 0 USDC (all transferred)
- Requires 2-step: First transfer back to source, then sync

### With Base Token Units (Implemented)

**When USDC appreciates:**
- Source VB: 0.5 ETH (FIXED) → NAV constant
- Destination: Real balance appreciates → NAV increases

**Result:** Destination gets performance AND holds the tokens ✅

**Benefit:** Can rebalance directly (1-step):
- Destination has high NAV and has tokens
- Transfer directly from destination to source

## Trade-offs

### Advantages

1. **Operational Simplicity**
   - Can rebalance when tokens appreciate (most common)
   - Performance on chain with physical custody
   - Direct 1-step rebalancing

2. **Gas Efficiency**
   - Single conversion (token → base)
   - Single storage write per chain
   - ~5,800 gas savings vs alternative

3. **Code Simplicity**
   - No special case handling
   - Fewer storage operations
   - Easier to audit and understand

### Disadvantages

1. **Conceptual Complexity**
   - Source "loses" ownership of appreciation
   - May seem unintuitive at first
   - Performance doesn't follow "origin"

2. **Rare Edge Case**
   - When tokens depreciate AND all tokens transferred
   - Requires 2-step rebalancing (dest→source→dest)
   - Uncommon in practice

## Rebalancing Scenarios

### Scenario 1: Token Appreciates (Common)

**State:**
- Source: Normal NAV, 0 tokens
- Destination: High NAV, has all tokens

**Rebalancing:**
```
Step 1: Transfer from destination to source (OpType.Transfer)
  - Moves tokens from high-NAV chain to normal-NAV chain
  - 1-step process ✅
```

### Scenario 2: Token Depreciates (Uncommon)

**State:**
- Source: Normal NAV, 0 tokens
- Destination: Low NAV, has all tokens

**Rebalancing:**
```
Step 1: Transfer from destination to source (OpType.Transfer)
  - Gets tokens to source
  
Step 2: Transfer from source to destination (OpType.Sync)
  - Moves performance attribution
  - 2-step process ⚠️
```

### Scenario 3: Regular Syncing (No Edge Case)

**State:**
- Source: Has some tokens (not all transferred)
- Destination: Has some tokens

**Rebalancing:**
```
Always 1-step in either direction ✅
```

## Mathematical Verification

### Source NAV Calculation

```
NAV = (Σ(token_i × price_i) + Σ(VB_baseToken × price_baseToken)) / supply

Where:
  token_i = real token balances
  VB_baseToken = base token virtual balance (FIXED)
  price_i = token prices
```

**When transferred token price changes:**
- `token_i` is 0 (transferred away)
- `VB_baseToken` is FIXED (doesn't change)
- **NAV remains constant** ✓

### Destination NAV Calculation

```
NAV = Σ(token_i × price_i) / (supply + VS)

Where:
  token_i = real token balances (including transferred tokens)
  VS = virtual supply (FIXED in share units)
```

**When transferred token price changes:**
- `token_i` includes the transferred tokens
- Price change affects numerator directly
- `VS` is FIXED (doesn't change)
- **NAV changes with token price** ✓

## Comparison with Alternative Approaches

| Aspect | Base Token VB (Implemented) | Token Unit VB (Not Implemented) |
|--------|---------------------------|--------------------------------|
| **Performance attribution** | Destination | Source |
| **Rebalancing (appreciate)** | ✅ 1-step | ⚠️ 2-step |
| **Rebalancing (depreciate)** | ⚠️ 2-step | ✅ 1-step |
| **Gas cost** | Lower (~8,900) | Higher (~14,700) |
| **Code complexity** | Simpler | More complex |
| **Storage writes** | 1-2 per side | 3 on destination |
| **Special cases** | None | token == baseToken |

## Conclusion

**Base token virtual balances** provide:
- ✅ Correct zero-sum attribution
- ✅ Practical rebalancing for common case (appreciation)
- ✅ Lower gas costs
- ✅ Simpler implementation
- ⚠️ Rare edge case (depreciation + full transfer) requires 2-step

This approach prioritizes practical operability and gas efficiency while maintaining mathematically correct performance attribution.
