# 0x Swap Aggregator Integration — Transaction Flow

> AI-friendly reference for the 0x swap aggregator integration with Rigoblock smart pools.

## Architecture Overview

```
Pool Owner → Pool Proxy (delegatecall) → A0xRouter adapter
                                             ↓ validates
                                             ↓ approves sellToken → AllowanceHolder
                                             ↓ calls
                                         AllowanceHolder.exec()
                                             ↓ sets ephemeral allowance
                                             ↓ forwards to
                                         Settler.execute()
                                             ↓ calls AllowanceHolder.transferFrom()
                                             ↓ executes swap (UniV3, RFQ, Curve, etc.)
                                             ↓ sends buyToken to recipient (pool)
```

## Key Addresses (Hardcoded — Same on All Supported Chains)

| Contract | Address | Notes |
|---|---|---|
| AllowanceHolder | `0x0000000000001fF3684f28c67538d4D072C22734` | Cancun chains |
| Deployer/Registry | `0x00000000000004533Fe15556B1E086BB1A72cEae` | All chains |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | All chains |

## Flow: Swap via AllowanceHolder

### Step 1: Client-side (off-chain)

1. Call 0x API `/swap/allowance-holder/quote` with `sellToken`, `buyToken`, `sellAmount`
2. API returns:
   - `transaction.to` = AllowanceHolder address
   - `transaction.data` = `AllowanceHolder.exec(operator, token, amount, target, data)`
   - `transaction.value` = native ETH value (if selling native)
3. Client sends `transaction.data` directly to the pool contract

### Step 2: Pool Proxy Routing

```
Pool.fallback()
  → selector = AllowanceHolder.exec.selector
  → Authority.getApplicationAdapter(selector) → A0xRouter
  → delegatecall A0xRouter.exec(operator, token, amount, target, data)
```

### Step 3: A0xRouter Validation (runs in pool context via delegatecall)

```solidity
exec(operator, token, amount, target, data):
  1. Verify `target` is a genuine 0x Settler via Deployer
     - Call Deployer.ownerOf(FEATURE_ID=2) to get current Taker Settler
     - If no match, call Deployer.prev(FEATURE_ID=2) for dwell-time fallback
     - Revert if neither matches (bridge/other settlers rejected implicitly)
  2. Decode `data` (Settler.execute calldata) to extract AllowedSlippage
     - recipient: MUST equal address(this) (the pool)
     - buyToken: MUST have a price feed in the oracle
  3. Derive ETH value from params: value = (token == address(0)) ? amount : 0
     - NEVER use msg.value — pool is the vault, sends its own ETH
  4. Approve exact sellToken amount to AllowanceHolder (per-call, not persistent)
  5. Forward call: AllowanceHolder.exec{value: value}(operator, token, amount, target, data)
  6. On success: reset ERC20 approval to 1 (keeps storage slot warm for gas savings)
     On failure: revert propagates, approval reverted automatically by EVM
```

### Step 4: AllowanceHolder Execution

```
AllowanceHolder.exec(operator, token, amount, target, data):
  1. _rejectIfERC20(target, data) — prevents confused deputy attack
  2. Sets ephemeral allowance: allowance[operator][pool][token] = amount
  3. Forwards: target.call{value}(data ++ pool_address)  // ERC-2771
  4. If pool is a contract (not tx.origin), clears ephemeral allowance after call
```

### Step 5: Settler Execution

```
Settler.execute(slippage, actions, zid):
  1. Executes first action (VIP: TRANSFER_FROM, UNISWAPV3_VIP, etc.)
     - TRANSFER_FROM calls AllowanceHolder.transferFrom(token, pool, settler, amount)
     - AllowanceHolder checks operator == msg.sender, deducts ephemeral allowance
     - AllowanceHolder calls ERC20.transferFrom(pool, settler, amount)
  2. Dispatches remaining actions (RFQ, UniswapV3, UniswapV2, Curve, etc.)
  3. _checkSlippageAndTransfer(slippage):
     - Checks buyToken balance >= minAmountOut
     - Transfers buyToken to recipient (pool)
```

## AllowanceHolder.exec Parameters

```solidity
function exec(
    address operator,   // Settler address (will call transferFrom)
    address token,      // Sell token (ERC20 or native sentinel)
    uint256 amount,     // Sell amount
    address payable target, // Settler contract address
    bytes calldata data // Settler.execute() calldata
) external payable returns (bytes memory result);
```

| Parameter | Validation | Notes |
|---|---|---|
| `operator` | Not validated directly | Must match `target` for the swap to succeed |
| `token` | Sell token; approved to AllowanceHolder | Skip approval if native ETH |
| `amount` | Sell amount | Ephemeral allowance amount |
| `target` | **MUST be verified as genuine Settler** | Via Deployer.ownerOf/prev |
| `data` | Decoded for AllowedSlippage | Contains Settler.execute calldata |

## Settler.execute Parameters (Inside `data`)

```solidity
function execute(
    AllowedSlippage calldata slippage,
    bytes[] calldata actions,
    bytes32 /* zid */
) external payable returns (bool);

struct AllowedSlippage {
    address payable recipient;  // MUST be pool address
    IERC20 buyToken;           // MUST have price feed
    uint256 minAmountOut;      // Slippage protection
}
```

### ABI Layout of `data`

```
Byte Offset  | Content
-------------|---------------------------
0-3          | Settler.execute selector
4-35         | slippage.recipient (address, left-padded)
36-67        | slippage.buyToken (address, left-padded)
68-99        | slippage.minAmountOut (uint256)
100-131      | offset to actions[] (dynamic)
132-163      | zid (bytes32)
...          | actions array data
```

## Settler Verification

The adapter uses the 0x Deployer/Registry contract to verify Settler instances.
This is the **recommended approach from the 0x team**.

```solidity
// Deployer is an ERC721-compatible NFT registry
// Feature IDs: 2 = Taker Submitted, 3 = MetaTxn, 4 = Intent, 5 = Bridge

function requireGenuineSettler(uint128 featureId, address allegedSettler) {
    // Check current Settler for this feature
    if (DEPLOYER.ownerOf(featureId) == allegedSettler) return; // OK
    // Fallback: check previous Settler (handles API dwell time)
    if (DEPLOYER.prev(featureId) == allegedSettler) return;    // OK
    revert CounterfeitSettler(allegedSettler); // Not genuine
}
```

**Why not `deployInfo`?**
- `ownerOf` + `prev` is the 0x-recommended approach
- Rejects paused/old Settler instances (only current + previous accepted)
- `deployInfo` would accept ANY historically deployed Settler, including buggy ones

**Dwell time**: When 0x deploys a new Settler, there's a lag before the API starts using it. During this period, `prev()` returns the address the API is still using.

## Security Model

### Price Feed Requirement
- buyToken MUST have a registered price feed in the pool's oracle
- Prevents operators from swapping into untracked/worthless tokens
- Same security model as the Uniswap adapter

### Recipient Validation
- AllowedSlippage.recipient MUST equal the pool address
- Prevents operators from directing swap output to external addresses

### Settler Verification
- Only accepts current or previous Settler instances from the Deployer registry
- Prevents forwarding funds to arbitrary contracts

### RFQ Safety
- RFQ market makers sign Permit2 witness messages for specific amounts/tokens
- Anyone can technically become an RFQ quoter (permissionless signing)
- The pool operator selects quotes via the 0x API (which returns the best available)
- **Risk analysis**: A rogue operator could register as an RFQ market maker, offer below-market
  quotes for specific pairs, and route pool swaps through their own quotes. This is a direct OTC
  drain: the operator IS the counterparty and personally benefits from the bad execution.
- **However**: This is the SAME trust model as any swap adapter. A rogue operator can equally
  make intentionally bad AMM trades (e.g., set amountOutMin = 1 and sandwich themselves).
  The economic outcome is identical — the pool loses value, visible in NAV.
- **Mitigations**:
  - `minAmountOut` in AllowedSlippage provides slippage protection (set by operator)
  - Price feed check prevents swapping into untracked/worthless tokens
  - NAV is transparent — investors can detect and withdraw on bad execution
  - Pool operator's own stake is at risk (skin in the game)
- **Conclusion**: RFQ presents no unique attack vector beyond the existing operator trust model.
  It is safe to include. All swap adapters inherently trust the operator to act in good faith.

### Cross-chain / Bridge Exclusion
- **How it works**: The adapter only verifies settlers against Feature 2 (Taker Submitted) in
  the Deployer registry. Feature 5 (Bridge) settlers have different contract addresses and are
  automatically rejected by `_requireGenuineSettler`.
- **Defense in depth**: Even if cross-chain actions were embedded within a Feature 2 settler's
  action list, they would fail at the settler's own `_checkSlippageAndTransfer` validation:
  bridged tokens do not arrive on the same chain in the same transaction, so the buyToken
  balance check fails and the settler reverts.
- **Virtual supply is not affected**: Since bridge transactions cannot execute through this
  adapter, there is no risk of cross-chain value transfer without proper virtual supply
  accounting. Cross-chain bridging is handled exclusively by AIntents/ECrosschain.

### Approval Pattern (Per-Call Approve/Reset)
- **How it works**: Before each exec call, the adapter approves the exact sellToken `amount`
  to AllowanceHolder. After successful execution, any remaining approval is reset to 0.
  On failure, the entire transaction reverts, unwinding the approval automatically.
- **AllowanceHolder does NOT use Permit2**: They are completely separate pathways in the
  0x architecture (see [0x-settler README](https://github.com/0xProject/0x-settler)).
  AllowanceHolder consumes standard ERC20 allowance via `token.transferFrom(pool, settler, amount)`.
  Since there is no second scoping layer (unlike Permit2), we approve per-call and reset.
- **Why not persistent max approval?** Without a second scoping mechanism like Permit2's
  block-scoped approval (expiration=0), a persistent max ERC20 approval to AllowanceHolder
  would leave the pool exposed if AllowanceHolder ever had a vulnerability.
- **Comparison with AUniswapRouter**: AUniswapRouter uses Permit2 (two-layer pattern):
  persistent ERC20 approval to Permit2, then per-block Permit2.approve (expiration=0)
  to the router. A0xRouter cannot use this pattern because AllowanceHolder is not Permit2.
  Instead: per-call ERC20 `safeApprove(amount)` → exec → `safeApprove(0)` reset.
- **USDT safety**: `safeApprove` handles USDT-style tokens that revert if setting non-zero
  allowance from non-zero (force reset to 0 first, then approve).

## Supported 0x Actions (Non-exhaustive)

| Action | Description | Custody |
|---|---|---|
| TRANSFER_FROM | Pull tokens via AllowanceHolder | No |
| UNISWAPV3_VIP | Optimized UniswapV3 swap | No |
| UNISWAPV3 | Standard UniswapV3 swap | Yes |
| UNISWAPV2 | UniswapV2/fork swap | Yes |
| UNISWAPV4 | UniswapV4 swap | Yes |
| RFQ | Request-for-Quote fill | No |
| BASIC | Generic DEX interaction | Yes |
| CURVE | Curve pool swap | Yes |
| VELODROME | Velodrome/Aerodrome swap | Yes |
| MAVERICKV2 | MaverickV2 swap | Yes |
| BALANCERV3 | BalancerV3 swap | Yes |
| DODO | DODO swap | Yes |

## Common Pitfalls

1. **Don't hardcode Settler addresses** — They change with each deployment. Always rely on on-chain verification via the Deployer registry.

2. **Native ETH sentinel** — 0x uses `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` for native ETH. The adapter maps this to `address(0)` for Rigoblock's oracle system.

3. **AllowanceHolder approval** — The pool approves the exact sell amount to AllowanceHolder
   for each call (not a persistent max approval). After successful execution, any remaining
   approval is reset to 0. On failure, the revert unwinds the approval automatically.

4. **Operator == Target** — In normal operation, the operator parameter equals the target (both are the Settler). If they differ, the swap will fail at AllowanceHolder.transferFrom.

5. **Only `execute` supported** — The adapter only accepts `Settler.execute()` calls, not `executeWithPermit()` or `executeMetaTxn()`. The AllowanceHolder flow uses `execute`.

## TypeScript Integration Example

```typescript
import { ethers } from "ethers";

// 1. Get quote from 0x API
const quoteResponse = await fetch(
  `https://api.0x.org/swap/allowance-holder/quote?` +
  `sellToken=${sellToken}&buyToken=${buyToken}&sellAmount=${amount}&taker=${poolAddress}`,
  { headers: { "0x-api-key": API_KEY, "0x-version": "2" } }
);
const quote = await quoteResponse.json();

// 2. Send transaction data directly to pool
// The pool's fallback will route to A0xRouter via Authority
const tx = await pool.connect(poolOwner).sendTransaction({
  to: poolAddress, // NOT AllowanceHolder — send to pool
  data: quote.transaction.data, // AllowanceHolder.exec calldata
  value: quote.transaction.value,
});
```

## Comparison with Uniswap Adapter

| Aspect | AUniswapRouter | A0xRouter |
|---|---|---|
| Entry points | `execute`, `modifyLiquidities` | `exec` |
| Approval target | Permit2 → Router (per-block) | AllowanceHolder (per-call approve/reset) |
| Calldata decoding | Full command/action decode | Decode AllowedSlippage only |
| Token validation | Decode all tokensOut | Extract buyToken from slippage |
| Recipient validation | Check all recipients | Check slippage.recipient |
| External verification | None (trusted router) | Deployer registry verification |
| Liquidity management | Yes (POSM positions) | No (swaps only) |
| Complexity | High (322 lines + 433 line decoder) | Low (~120 lines) |
