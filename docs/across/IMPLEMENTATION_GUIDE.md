# Across Bridge Integration - Complete Guide

This document consolidates all aspects of the Across bridge integration for Rigoblock smart pools.

## Table of Contents
1. [Architecture Overview](#architecture-overview)
2. [Implementation Details](#implementation-details)
3. [Known Issues & Edge Cases](#known-issues--edge-cases)
4. [Deployment Guide](#deployment-guide)
5. [Testing Strategy](#testing-strategy)
6. [Risk Assessment](#risk-assessment)

---

## Architecture Overview

### Components

1. **AIntents.sol** (Adapter)
   - Entry point for cross-chain transfers
   - Validates inputs and prepares Across deposits
   - Manages virtual balances on source chain
   - Location: `protocol/extensions/adapters/AIntents.sol`

2. **ECrosschain.sol** (Extension)
   - Handles incoming transfers on destination chain
   - Called via delegatecall by pool proxy
   - Validates transfers and manages virtual balances
   - Location: `protocol/extensions/ECrosschain.sol`

3. **ExtensionsMapDeployer.sol** (Deps)
   - Deploys ExtensionsMap with chain-specific params
   - Maps ECrosschain methods to delegatecall
   - Location: `protocol/deps/ExtensionsMapDeployer.sol`

4. **ENavView.sol** (Utility)
   - Provides offchain nav calculations
   - Returns token balances and nav values
   - Location: `protocol/extensions/ENavView.sol`

### Message Types

The integration supports two operation modes via encoded message:

#### Type 1: Transfer (OpType.Transfer)
- Source chain NAV made neutral via virtual adjustments
- Destination chain NAV made neutral via virtual adjustments
- Bridge fees reduce global NAV (real economic cost)
- Use case: Moving assets between chains without affecting NAV

#### Type 2: Sync (OpType.Sync)
- No virtual adjustments on either chain
- NAV changes allowed (donations, rebalancing)
- NavImpactLib validates NAV tolerance on source
- Destination validates NAV is within expected range
- Use case: Donations, performance transfers, allowing solver surplus to benefit holders

---

## Implementation Details

### Transfer Flow (OpType.Transfer)

**Source Chain (AIntents.depositV3):**
1. Validate inputs (amount, token, destination chain)
2. Wrap native currency if needed
3. Approve token to Across SpokePool
4. Adjust virtual balances/supply (NAV-neutral)
5. Call Across depositV3 with encoded multicall instructions
6. Emit CrossChainTransfer event

**Destination Chain (ECrosschain.handleV3AcrossMessage → donate):**
1. Verify caller is Across SpokePool
2. Decode message and validate type
3. Store NAV baseline in transient storage
4. For Transfer mode: Apply virtual balance/supply adjustments (NAV-neutral)
5. Verify token has price feed
6. Validate final NAV matches expected (stored NAV + solver surplus)

### Sync Flow (OpType.Sync)

**Source Chain:**
1. Calculate NAV before transfer
2. Validate NAV impact is within tolerance (NavImpactLib)
3. Encode Sync mode in message
4. Execute transfer (NAV decreases naturally)

**Destination Chain:**
1. Store NAV baseline in transient storage
2. No virtual adjustments (allow NAV to increase)
3. Validate NAV is within tolerance of expected
4. Solver surplus increases NAV (benefits holders)

### Virtual Balance & Supply Management

Virtual balances and virtual supply ensure NAV integrity for transfers:

**Virtual Supply** (global cross-chain share tracking):
```solidity
// Denominated in pool token units (shares)
// Tracks pool tokens that exist on other chains
int256 virtualSupply;
```

**Virtual Balances** (per-token NAV offsets):
```solidity
// Denominated in token-specific units
// Offsets physical balance changes for NAV neutrality
mapping(address token => int256 virtualBalance);
```

**Source Chain (Transfer Mode)**:
```solidity
// Try to burn virtual supply first (if exists)
if (virtualSupply >= sharesToBurn) {
    adjustVirtualSupply(-sharesToBurn);
} else if (virtualSupply > 0) {
    // Burn all virtual supply, use virtual balance for remainder
    adjustVirtualSupply(-virtualSupply);
    adjustVirtualBalance(token, remainderInTokenUnits);
} else {
    // No virtual supply - use virtual balance entirely
    adjustVirtualBalance(token, scaledOutputAmount);
}
```

**Destination Chain (Transfer Mode)**:
```solidity
// Reduce positive virtual balances first (tokens returning)
if (virtualBalance > 0) {
    adjustVirtualBalance(token, -min(amount, virtualBalance));
}

// Increase virtual supply for remaining amount
if (remainingAmount > 0) {
    uint256 shares = convertTokensToShares(remainingAmount, storedNav);
    adjustVirtualSupply(shares);
}
```

Stored in pool storage using ERC-7201 namespaced slots with dot notation.

---

## Known Issues & Edge Cases

### 1. Unfilled Intent Recovery

**Issue:** If an Across intent is not filled within deadline, tokens should be recoverable.

**Current State:** No direct recovery mechanism implemented.

**Implications:**
- Tokens remain in virtual balance accounting
- Pool operator could potentially inflate nav by:
  1. Setting very short deadline
  2. Locking tokens (creating positive virtual balance)
  3. Receiving refund without clearing virtual balance

**Mitigation:**
- Document as known issue
- Recommend reasonable deadlines at client level
- Consider monitoring for suspicious patterns

**Risk Level:** 4/10 (requires pool operator malfeasance, limited by audit trail)

### 2. External Token Returns

**Issue:** If Across returns tokens directly to pool (edge case), nav accounting breaks.

**Current State:** Not handled automatically.

**Implications:**
- Virtual balance remains, offsetting real tokens
- Nav calculation temporarily incorrect
- Requires manual intervention

**Mitigation:**
- Document as edge case
- Provide manual recovery process if needed
- Monitor for such occurrences

**Risk Level:** 2/10 (very rare, affects single pool, reversible)

### 3. Wrapper Contract Consideration

**Complexity Assessment:** 7/10

**Approach:**
- Deploy per-pool wrapper contract
- Pool deploys wrapper on-demand
- Wrapper executes Across transfer
- Refunds go to wrapper, not pool
- Pool can claim from wrapper with virtual balance update

**Cons:**
- Increases implementation size (deploy bytecode)
- Higher gas costs (extra deployment + contract)
- Additional complexity in recovery logic
- Requires wrapper state management

**Risk Reduction:** 2/10 → 1/10 (minimal improvement)

**Conclusion:** Not worth the complexity given low baseline risk.

### 4. Price Feed Requirement

**Issue:** Destination chain must have price feed for received token.

**Handling:** ECrosschain reverts if no price feed found.

**Result:** Intent fails, tokens recoverable on source chain.

**Risk Level:** 0/10 (safe failure mode)

---

## Deployment Guide

### Prerequisites

All chains must have:
- Across SpokePool deployed
- Rigoblock infrastructure (Authority, Registry, Factory)
- Price oracle with token feeds

### Deployment Steps

#### 1. Deploy ExtensionsMapDeployer

```solidity
// Deploy on each chain with chain-specific params
new ExtensionsMapDeployer({
    wrappedNativeToken: WETH_ADDRESS,
    acrossSpokePool: SPOKE_POOL_ADDRESS,
    // ... other params
});
```

#### 2. Deploy ExtensionsMap

```solidity
// Call from deployer
deployer.deploy(salt); // Use incremented salt for versions
```

#### 3. Deploy ECrosschain

```solidity
// ExtensionsMapDeployer handles this automatically
// ECrosschain immutables set from deployer params
```

#### 4. Deploy AIntents

```solidity
// Same address on all chains (deterministic)
new AIntents();
```

#### 5. Register Adapter Methods

```solidity
// Via governance vote
authority.addMethod(
    DEPOSITV3_SELECTOR,
    address(aIntents),
    IAuthority.MethodPermission.PoolOperator
);
```

#### 6. Deploy New Implementation

```solidity
// Factory upgrade to implementation using new ExtensionsMap
factory.setImplementation(newImplementation);
```

### Verification

- Test transfer Type 1 on testnet
- Test rebalance Type 2 on testnet
- Verify virtual balances update correctly
- Verify nav calculations remain accurate
- Test price feed validation

---

## Testing Strategy

### Unit Tests (Hardhat/TypeScript)

**File:** `test/offchain/offchainNav.test.ts`

Tests for OffchainNav contract:
- Token balances return correctly
- Nav calculations match storage values
- Virtual balances included in calculations
- Multiple token scenarios

**File:** `test/adapters/aIntents.test.ts` (TBD)

Tests for AIntents:
- Deposit validation
- Virtual balance creation
- Message encoding
- Event emission

### Fork Tests (Foundry)

**File:** `test/AcrossFork.t.sol`

Tests on mainnet/arbitrum forks:
- Full transfer flow (Type 1)
- Full rebalance flow (Type 2)
- Nav sync between chains
- Error conditions (no price feed, invalid params)
- Direct call prevention (security)

**Setup Requirements:**
- Fork at recent block
- Use existing vault or deploy new one
- Prank as pool operator
- Mock Across SpokePool responses

### Integration Tests

**Manual Testing:**
- Deploy on testnet (Sepolia)
- Execute real cross-chain transfer
- Verify tokens received
- Verify nav calculations
- Test recovery scenarios

---

## Risk Assessment

### Overall Risk Profile

**Current Implementation Risk:** 3.5/10

**Primary Risks:**
1. Unfilled intent nav inflation (4/10) - requires operator malfeasance
2. External token returns (2/10) - very rare edge case
3. Nav sync edge cases (3/10) - mitigated by delta tracking
4. Price feed failures (0/10) - safe revert

**Recommended Monitoring:**
- Track virtual balances vs actual balances
- Monitor intent fill rates
- Alert on unusual deadline patterns
- Track nav divergence between chains

**Future Improvements:**
1. Implement intent recovery mechanism (if Across adds support)
2. Add virtual balance reconciliation tool
3. Enhanced nav sync verification
4. Automated monitoring dashboard

---

## References

- [Across Protocol Docs](https://docs.across.to/)
- [Rigoblock Docs](https://docs.rigoblock.com/)
- [Deployed Contracts](https://docs.rigoblock.com/readme-2/deployed-contracts-v4)

---

*Last Updated: 2025-12-11*
*Integration Version: 1.0.0*
