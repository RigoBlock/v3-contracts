# Performance Rebalancing (VS-Only Model)

## Overview

This document explains how to rebalance performance between chains using the VS-only model.

## Key Insight: VS-Only Simplifies Rebalancing

With the VS-only model, performance is **already shared proportionally** between chains through the effective supply mechanism. This eliminates most rebalancing complexity.

## Transfer vs Sync Modes

### Transfer Mode (OpType.Transfer)

**Behavior:**
- Source: Writes **negative VS** (shares leaving)
- Destination: Writes **positive VS** (shares arriving)
- Both chains: NAV unchanged

**Use for:**
- Moving liquidity between chains
- NAV-neutral token movement

### Sync Mode (OpType.Sync)

**Behavior:**
- Source: No VS adjustment → NAV decreases (tokens leave)
- Destination: No VS adjustment → NAV increases (tokens arrive)
- Both chains: NAV changes naturally

**Use for:**
- Performance rebalancing
- Donations
- Intentional NAV adjustments

## Rebalancing Scenarios

### Scenario 1: Equalizing Chain NAVs

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

### Scenario 2: Emergency Liquidity

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

### Scenario 3: Consolidating Assets

**Situation:**
- Pool has assets scattered across 5 chains
- Want to consolidate on one chain

**Solution:** Sequential Transfers
```
For each source chain:
1. Transfer all tokens to destination (Transfer mode)
2. Source ends with negative VS = 100% of supply sent
3. Destination accumulates positive VS

Note: 10% constraint limits single transfer to 90% of effective supply
```

## Safety Constraints

### 10% Effective Supply Buffer

**Rule:** Cannot transfer more than 90% of effective supply in a single Transfer.

```
Effective Supply = Total Supply + Virtual Supply
Minimum Required: 10% of Total Supply
```

**Why:** Ensures pool remains functional with positive effective supply.

**Workaround for full consolidation:**
1. Transfer 80%
2. Users burn shares, reducing total supply
3. Transfer remaining 80% of new effective supply
4. Repeat until consolidated

### Post-Burn Protection

Burns cannot push effective supply below 10% threshold. This prevents:
- Bypassing transfer constraint via burn + transfer
- Supply exhaustion attacks

## Comparison with Previous VB+VS Approach

| Scenario | VS-Only | VB+VS (Previous) |
|----------|---------|------------------|
| NAV-neutral transfer | ✅ 1 operation | ✅ 1 operation |
| Performance rebalancing | ✅ Sync mode | ⚠️ Complex (VB coordination) |
| Full consolidation | ⚠️ Multi-step (10% limit) | ⚠️ Multi-step (VB clearing) |
| Edge cases | ✅ None | ⚠️ 2-step for depreciation |

## Summary

The VS-only model provides:
- ✅ Simpler rebalancing (no VB to coordinate)
- ✅ Proportional performance sharing by default
- ✅ Clear distinction between Transfer (NAV-neutral) and Sync (NAV-impacting)
- ✅ Single constraint to manage (10% effective supply)

Sync mode enables intentional NAV changes for performance rebalancing, while Transfer mode maintains NAV neutrality for liquidity movement.
