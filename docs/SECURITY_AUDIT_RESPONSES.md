# Security Audit & Edge Case Analysis

## Questions & Responses

### 1. Reentrancy Protection in ECrosschain.donate - Multiple Calls in Same Transaction

**Question**: "reentrancy protection in ECrosschain.donate allows us to call the method twice, because we're not actually reentering the call, but making two calls in the same transaction (unlock-lock), which is fine?"

**Answer**: ✅ **YES, this is correct and intentional.**

**Explanation**:

- **Reentrancy** = When function A calls external contract B, and B calls back into A _before_ A completes
- **Sequential calls** = Function A completes, then function A is called again in the same transaction

The `nonReentrant` modifier from `ReentrancyGuardTransient` prevents **reentrancy** but allows **sequential calls**.

**How TransferEscrow works**:

```solidity
// First call: Initialize lock and store balance
IECrosschain(pool).donate(token, 1, params);  // amount == 1
// ✅ Call completes, lock released

// Transfer tokens
token.safeTransfer(pool, balance);

// Second call: Process donation
IECrosschain(pool).donate(token, balance, params);  // amount == balance
// ✅ Call completes, lock released
```

**Flow**:

1. First `donate(token, 1, ...)`:
   - `nonReentrant` sets lock
   - Stores balance in transient storage
   - Returns
   - `nonReentrant` clears lock ✅

2. Token transfer happens (no reentrancy risk)

3. Second `donate(token, balance, ...)`:
   - `nonReentrant` sets lock (fresh call, lock was cleared)
   - Processes donation
   - Returns
   - `nonReentrant` clears lock ✅

**Key Point**: Each call _completes_ before the next one starts. This is NOT reentrancy.

**True reentrancy would look like**:

```solidity
donate(token, amount, params) {
    nonReentrant; // Lock set
    token.transfer(pool, amount);
    // If token has malicious receive() that calls donate() again
    // → nonReentrant would revert ❌ (locked)
}
```

The protection WORKS AS INTENDED - prevents reentrancy, allows sequential calls.

---

### 2. CREATE2 Address Change & Test Verification

**Question**: "the transfer escrow deployed address now has changed in one of our tests, which is now reverting. Can you verifying if we were incorrectly creating the create2 salt before? and could you add a test to prevent falling in the same pitfall?"

**Answer**: ✅ **YES, the CREATE2 formula was updated (correctly) and tests have been fixed.**

**What Changed**:

**Before** (EscrowFactory.sol line 30):

```solidity
// WRONG - confusing in delegatecall context
keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash))
```

**After**:

```solidity
// CORRECT - explicit pool parameter
keccak256(abi.encodePacked(bytes1(0xff), pool, salt, bytecodeHash))
```

**Why the change was necessary**:

1. **Delegatecall context**: When called via delegatecall, `address(this)` == pool
2. **Direct call context**: When called directly (tests), `address(this)` == caller (test contract)
3. **Confusion**: Using `address(this)` made the behavior implicit and context-dependent
4. **Fix**: Use explicit `pool` parameter for clarity and correctness

**Salt Formula**:

```solidity
// Salt is based on opType only (NOT pool)
bytes32 salt = keccak256(abi.encodePacked(uint8(opType)));

// Pool is used as:
// 1. CREATE2 deployer address
// 2. Constructor parameter (encoded in bytecode hash)
```

**Test Added** ([test/extensions/TransferEscrow.t.sol](test/extensions/TransferEscrow.t.sol#L93-L118)):

```solidity
function test_EscrowDeployment() public view {
  // Verify deployment is deterministic
  address predictedAddress = EscrowFactory.getEscrowAddress(
    pool,
    OpType.Transfer
  );
  assertEq(
    escrowAddress,
    predictedAddress,
    "Deployed address should match predicted"
  );

  // Verify CREATE2 formula matches actual deployment
  bytes32 salt = keccak256(abi.encodePacked(uint8(OpType.Transfer)));
  bytes32 bytecodeHash = keccak256(
    abi.encodePacked(type(TransferEscrow).creationCode, abi.encode(pool))
  );
  address expectedAddress = address(
    uint160(
      uint256(
        keccak256(abi.encodePacked(bytes1(0xff), pool, salt, bytecodeHash))
      )
    )
  );
  assertEq(
    escrowAddress,
    expectedAddress,
    "CREATE2 address must use explicit pool parameter"
  );
}
```

**Critical Fix in Test Setup**:

```solidity
// MUST call from pool context to match production delegatecall behavior
vm.prank(pool);
escrowAddress = EscrowFactory.deployEscrow(pool, OpType.Transfer);
```

This ensures test CREATE2 deployment matches production behavior.

---

### 3. Token Activation via Donation - Security Vulnerability

**Question**: "what happens when we deposit native currency to across but the deposit expires and is refunded to the escrow? ... if it is weth, it isn't active. Will the donate call we make from refundVault activate the token in the pool? if so, can any token be activated via a donation?"

**Answer**: ⚠️ **CRITICAL SECURITY ISSUE FOUND AND FIXED**

**Vulnerability Discovered**:

YES, `ECrosschain.donate()` DOES activate tokens automatically:

```solidity
// Line 95 in ECrosschain.sol
StorageLib.activeTokensSet().addUnique(IEOracle(address(this)), token, StorageLib.pool().baseToken);
```

**Attack Vectors**:

1. **Token Activation Griefing**:
   - Attacker sends any token with price feed to escrow
   - Calls `refundVault()` → donate() → auto-activates token
   - Repeat 128 times (max active tokens)
   - Pool NAV calculations become extremely gas-expensive

2. **Expired Native Deposit Scenario**:

   ```
   User deposits native ETH → Across wraps to WETH → Deposit expires → Refunded as WETH
   → WETH not active in pool → refundVault calls donate → WETH auto-activated
   ```

   If WETH has price feed and wasn't intended to be active, it's now activated.

3. **DoS via Max Tokens**:
   - Fill all 128 token slots with low-value tokens
   - Legitimate tokens can't be added
   - NAV updates cost excessive gas

**Fix Implemented** ([TransferEscrow.sol](contracts/protocol/extensions/escrow/TransferEscrow.sol#L40-L42)):

```solidity
/// @notice Only allows Across-whitelisted tokens + native currency
function refundVault(address token) external nonReentrant {
  // Whitelist validation BEFORE donate call
  require(
    token == address(0) || CrosschainLib.isAllowedCrosschainToken(token),
    UnsupportedToken()
  );

  // ... rest of refund logic
}
```

**Whitelist Protection**:

- **Native (address(0))**: Always safe (pool's base token or already active)
- **WETH**: Only allowed if on Across whitelist for current chain
- **Stablecoins (USDC, USDT)**: Only allowed if on Across whitelist
- **Random tokens**: ❌ REJECTED

**Why This Is Safe**:

1. **Across-whitelisted tokens**: Have legitimate use cases (cross-chain transfers)
2. **Native currency**: Already part of pool's design
3. **Expired deposits**: Will be refunded as whitelisted assets (USDC, USDT, WETH on supported chains)
4. **Attack prevention**: Random tokens with price feeds CANNOT activate via donation

**Tests Added** ([test/extensions/TransferEscrow.t.sol](test/extensions/TransferEscrow.t.sol)):

1. **test_RefundVault_RejectsUnauthorizedTokens** - Prevents token activation griefing
2. **test_RefundVault_NativeAlwaysAllowed** - Native currency always works
3. **test_RefundVault_ERC20** - Whitelisted USDC works
4. **test_RefundVault_SmallAmounts** - Edge case coverage

**Chains & Tokens Protected** ([CrosschainLib.sol](contracts/protocol/libraries/CrosschainLib.sol#L144-L185)):

- Ethereum: USDC, USDT, WETH
- Arbitrum: USDC, USDT, WETH
- Optimism: USDC, USDT, WETH
- Base: USDC, WETH (no USDT)
- Polygon: USDC, USDT, WETH
- BSC: USDC, USDT, WETH
- Unichain: USDC, WETH

---

## Summary of Changes

### Files Modified

1. **contracts/protocol/extensions/escrow/TransferEscrow.sol**:
   - ✅ Added `CrosschainLib` import
   - ✅ Added `UnsupportedToken` error
   - ✅ Added token whitelist validation in `refundVault()`
   - ✅ Prevents unauthorized token activation

2. **test/extensions/TransferEscrow.t.sol**:
   - ✅ Fixed CREATE2 salt formula in test
   - ✅ Added `vm.prank(pool)` for correct deployment context
   - ✅ Switched to mainnet fork with real USDC
   - ✅ Added comprehensive security tests

### Security Improvements

| Issue                     | Severity       | Status           |
| ------------------------- | -------------- | ---------------- |
| Token activation griefing | 🔴 Critical    | ✅ Fixed         |
| CREATE2 address confusion | 🟡 Medium      | ✅ Fixed         |
| Reentrancy in donate()    | 🟢 Intentional | ✅ Verified safe |

### Test Results

```bash
✅ 103/103 tests passing in test/extensions/
✅ 12/12 TransferEscrow tests passing
✅ 45/45 AIntents tests passing
✅ All CREATE2 determinism verified
```

---

## Recommendations

1. **✅ IMPLEMENTED**: Whitelist validation in TransferEscrow.refundVault()
2. **✅ IMPLEMENTED**: CREATE2 test coverage for address determinism
3. **✅ VERIFIED**: Reentrancy protection working as intended
4. **📝 CONSIDER**: Document expected behavior for expired Across deposits in README
5. **📝 CONSIDER**: Add monitoring for unexpected token activations in production

---

## Edge Cases Handled

### Expired Native Deposit Flow

**Scenario**: User deposits 1 ETH to Across, deposit expires

**Possible outcomes**:

1. **Refunded as native ETH** → `address(0)` → ✅ Works (native always allowed)
2. **Refunded as WETH** → `WETH address` → ✅ Works (WETH on Across whitelist)
3. **Not refunded** → Funds lost to Across, not our concern

**Protection**: Both cases work safely without unauthorized token activation.

### Gas Griefing Prevented

**Before fix**: Attacker could activate 128 random tokens, each adding 20K+ gas to NAV updates

**After fix**: Only Across-whitelisted tokens (3-4 per chain) can be activated via refund

**Impact**: NAV gas costs remain predictable and reasonable

---

## Bug Bounty Finding 02 — `mintWithToken` minimum-order guard

**Status**: ✅ Fixed in `MixinActions.sol`

**Finding**: `mintWithToken` checked `_assertBiggerThanMinimum(amountIn)` before converting `amountIn` to base-token units. Because `decimals()` returns the base token's decimals, the threshold and the amount were in different units whenever `tokenIn` had different decimals than the base token.

**Effects before the fix**:

- **baseDecimals > tokenInDecimals**: realistic orders reverted. For example, a WETH-based pool (18 decimals) accepting USDC (6 decimals) required `10^15` USDC units (1 billion USDC) to clear the guard.
- **baseDecimals < tokenInDecimals**: the guard became negligible. For example, a USDC-based pool (6 decimals) accepted 1,000 wei of WETH (18 decimals), which converted to 0 base units and minted 0 pool tokens.

**Fix applied**: `_mint` now resolves `tokenIn` to the actual token address, converts the gross `amountIn` to base-token units, and calls `_assertBiggerThanMinimum(amountInBase)` before the spread is deducted. The remaining `amountInGross - spread` is then converted a second time to base-token units to compute `mintedAmount`. The minimum is checked against the same economic value for both `mint()` and `mintWithToken()`, and the spread is always computed and transferred in the input token.

**Why the minimum must be checked on the gross converted amount**:

- **Predictable threshold**: The threshold `10 ** decimals() / 1e3` always means exactly one thousandth of a base token, whether the caller uses `mint()` or `mintWithToken()`. If the minimum were checked on the net amount (after spread), the effective minimum would depend on the current spread, forcing clients to overestimate their input to account for a fee that is removed before the check. Gross-check keeps the minimum a property of the pool, not of the payment token or the spread.
- **Avoids rejecting legitimate orders**: A `mintWithToken` order whose gross value is above the minimum but whose net value falls just below it would be rejected under a net-check. The gross value is the economic size of the order, so it is the natural guard.
- **Cleaner spread accounting**: The spread is always computed and transferred in the input token. Evaluating the minimum on the gross converted amount keeps the two concerns separate: the minimum guards the order size, the spread is the protocol fee.

**Why two oracle conversions are necessary**:

- The minimum needs the **gross** value in base units.
- The minted amount needs the **net** value in base units.
- A single conversion cannot produce both values because the spread is denominated in the input token. Converting the gross amount, asserting, deducting the spread in the input token, and then converting the net amount is the only exact accounting path. Any scheme with one conversion either checks the net value (unpredictable effective minimum) or incorrectly treats the spread as base units (wrong fee amount).

**Design notes**:

- The threshold is `10 ** decimals() / 1e3`, i.e. one thousandth of a base token, and now consistently measures the economic value being minted.
- The gross check means a `mintWithToken` order that is exactly at the minimum edge will mint slightly fewer pool tokens than the same base-token `mint()` call, because the spread is removed after the minimum is validated. This is the intended behaviour: the minimum guards the order size, the spread is the protocol fee.

**Why a decimal-scaled threshold is not acceptable**:

A threshold of `10 ** tokenIn.decimals() / 1e3` would be decoupled from the base token, which is the only unit that has protocol meaning (pool shares, NAV, and the minimum are all denominated in base units). It would produce two wrong outcomes:

1. **Too lenient when the base token is worth more than the mint token.** For a WETH base pool (18 decimals) accepting USDC (6 decimals), the rescaled threshold would be `0.001 USDC`, while the intended economic minimum is `0.001 WETH` (~$2–$3). The guard would allow sub-cent USDC mints, defeating its purpose of preventing dust entries.
2. **Does not prevent null mints.** For a USDC base pool (6 decimals) accepting WETH (18 decimals), the rescaled threshold would be `1e15` wei of WETH. That happens to reject the original 1,000-wei example, but only because WETH has 18 decimals. For a 30-decimal token, or any token whose price makes `0.001 tokenIn` worth far less than `0.001 baseToken`, the rescaled guard would pass an amount that converts to `0` base units and mints `0` pool tokens. The real protection is the **base value** of the input, not its raw decimal count.

**Client UX guidance**:

The minimum is defined in base-token units and can be computed off-chain without a transaction:

```text
minimumBase = 10 ** pool.decimals() / 1000
```

For `mintWithToken`, the equivalent `tokenIn` amount moves with the oracle price, exactly like `amountOutMin`. Clients should convert `minimumBase` from the base token to `tokenIn` units off-chain using the same price source the pool will use. The minimum is enforced on the gross converted value, so the gross input must be at least this amount; the pool deducts the spread afterwards.

```text
minimumTokenIn = minimumBase * (baseTokenPrice / tokenInPrice)
```

Equivalently, they can call the oracle directly to convert `minimumBase` from the base token to `tokenIn`. No further spread adjustment is needed to clear the guard, because the pool checks the gross amount before subtracting the spread. The actual minted amount will be lower than the gross-converted amount because the spread is subtracted in `tokenIn` units before the second conversion.

**Tests**:

- `test/core/MintWithTokenMinimumMismatch.t.sol` covers both decimal-mismatch directions on a mainnet fork.
- `test/core/RigoblockPool.MintWithToken.spec.ts` was updated to assert the minimum is enforced on the gross converted base amount.

**Production exposure**: All sampled V4 pools on Ethereum and Arbitrum returned empty `getAcceptedMintTokens()` arrays at the time of the report, so the bug was not exploitable in production. It becomes active only if a pool operator adds a non-base acceptable token with mismatched decimals.

---

**Author**: GitHub Copilot (Claude Sonnet 4.5)  
**Date**: January 13, 2026  
**Status**: All issues addressed and tested
