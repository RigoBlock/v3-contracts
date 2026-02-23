# Uniswap Transaction Flow Through Rigoblock Smart Pools

## Quick Reference

| Operation | Entry Point | Adapter Method | Uniswap Target |
|---|---|---|---|
| V2/V3/V4 swaps | `execute(commands, inputs, deadline)` | `0x3593564c` | Universal Router |
| V2/V3/V4 swaps (no deadline) | `execute(commands, inputs)` | `0x24856bc3` | Universal Router |
| V4 liquidity (mint/burn/increase/decrease) | `modifyLiquidities(unlockData, deadline)` | `0xdd46508f` | V4 PositionManager |

**Key files:**
- Adapter: `contracts/protocol/extensions/adapters/AUniswapRouter.sol`
- Decoder: `contracts/protocol/extensions/adapters/AUniswapDecoder.sol`
- Interface: `contracts/protocol/extensions/adapters/interfaces/IAUniswapRouter.sol`
- Authority: `contracts/protocol/deps/Authority.sol`
- Pool fallback: `contracts/protocol/core/sys/MixinFallback.sol`

---

## Architecture: How Calls Reach the Adapter

```
User (pool owner) calls pool.execute(commands, inputs, deadline)
         │
         ▼
   Pool Proxy (fixed address)
         │  selector 0x3593564c not found on SmartPool implementation
         ▼
   MixinFallback.fallback()
         │  1. Check ExtensionsMap → not found (adapters aren't extensions)
         │  2. Authority.getApplicationAdapter(0x3593564c) → AUniswapRouter address
         │  3. msg.sender == pool.owner? → yes → delegatecall
         ▼
   AUniswapRouter.execute() [runs in pool storage context via delegatecall]
         │
         ├─ Phase 1: DECODE — extract Parameters from calldata (memory only)
         ├─ Phase 2: VALIDATE — check recipients, price feeds, set approvals
         ├─ Phase 3: FORWARD — pass original calldata unmodified to Uniswap
         └─ Phase 4: POST-PROCESS — update token/position tracking (storage writes)
```

### Access Control

- **Only the pool owner** can call adapter methods in write mode (delegatecall)
- **Anyone** can call adapter methods in read mode (staticcall) — used for view functions
- The adapter runs via `delegatecall`, so `address(this)` is the pool proxy and storage modifications affect the pool
- The adapter verifies `address(this) != _adapter` (onlyDelegateCall modifier) to prevent direct calls

### Authority Registration

The adapter's three selectors must be registered in the Authority contract:
```solidity
authority.setAdapter(aUniswapRouterAddress, true);   // whitelist the adapter
authority.addMethod(0x3593564c, aUniswapRouterAddress); // execute(bytes,bytes[],uint256)
authority.addMethod(0x24856bc3, aUniswapRouterAddress); // execute(bytes,bytes[])
authority.addMethod(0xdd46508f, aUniswapRouterAddress); // modifyLiquidities(bytes,uint256)
```

---

## Phase 1: Decode (Memory Only)

The decoder extracts metadata from calldata into a `Parameters` struct without modifying the original calldata:

```solidity
struct Parameters {
    uint256 value;       // native ETH to send with the Uniswap call
    address[] recipients; // all recipient addresses (must be pool or router)
    address[] tokensIn;   // tokens the pool will spend (need Permit2 approval)
    address[] tokensOut;  // tokens the pool will receive (must have price feeds)
}
```

For `modifyLiquidities`, an additional `Position[]` array tracks liquidity position state changes:

```solidity
struct Position {
    address hook;     // V4 hook address (checked for delta permissions on mint)
    uint256 tokenId;  // 0 for new mints, actual ID for existing positions
    uint256 action;   // MINT_POSITION, BURN_POSITION, INCREASE/DECREASE_LIQUIDITY
}
```

### When tokensIn Are Determined

Token approvals (`tokensIn`) are set only when the token flow direction is unambiguous:

| Action | tokensIn set? | Why |
|---|---|---|
| `MINT_POSITION` | Yes (currency0 + currency1) | Tokens always flow in on mint |
| `INCREASE_LIQUIDITY` | Yes (currency0 + currency1) | Tokens always flow in on increase |
| `SETTLE_PAIR` | Yes (currency0 + currency1) | Explicit settlement of tokens |
| `SETTLE` / `SETTLE_ALL` | Yes | Explicit settlement of tokens |
| `CLOSE_CURRENCY` | No (tokensOut only) | Direction ambiguous — may settle or take |
| `CLEAR_OR_TAKE` | No (tokensOut only) | Takes remaining balance |
| `V3_SWAP_EXACT_IN` | Yes (first token in path) | First address is input token |
| `V2_SWAP_EXACT_IN` | Yes (path[0]) | First address is input token |

---

## Phase 2: Validate

Three validation steps run before forwarding:

### 2a. Recipient Validation (`_processRecipients`)
Every decoded recipient must be one of:
- `address(this)` — the pool proxy itself
- `ActionConstants.MSG_SENDER` — Uniswap's flag for the caller (which is the pool)
- `ActionConstants.ADDRESS_THIS` — Uniswap's flag for the router/POSM contract

This prevents the pool owner from routing tokens to personal addresses.

### 2b. Price Feed Assertion (`_assertTokensOutHavePriceFeed`)
Every output token must have an active price feed in the oracle extension. This ensures:
- The pool's NAV can be calculated after the trade
- The token is added to the pool's active tokens set (tracked for NAV accounting)
- Prevents the owner from acquiring tokens that can't be valued

### 2c. Token Approval (`_safeApproveTokensIn`)
For each input token:
1. Approve `type(uint256).max` to Permit2 (one-time, persistent)
2. Call `permit2.approve(token, target, type(uint160).max, 0)` — expiration `0` means the approval is valid only within the current block

This pattern avoids repeated `approve` gas costs while limiting exposure to a single block.

---

## Phase 3: Forward

The original calldata is forwarded **unmodified** to Uniswap:

```solidity
// For swaps via Universal Router
_uniswapRouter.execute{value: params.value}(commands, inputs);

// For liquidity via PositionManager
_uniV4Posm.modifyLiquidities{value: newParams.value}(unlockData, deadline);
```

This is the most gas-efficient approach — no re-encoding overhead. The adapter is a validation layer, not a transformation layer.

### Error Handling

Both calls use try/catch. On failure:
1. `catch Error(string memory reason)` — re-throws Solidity string errors
2. `catch (bytes memory returnData)` — checks if failure is due to insufficient native balance (custom error), otherwise re-throws the raw error bytes via assembly

---

## Phase 4: Post-Process (`modifyLiquidities` only)

After successful `modifyLiquidities` execution, `_processTokenIds` updates pool storage:

### Mint Tracking
- Compares `nextTokenId` before/after to detect newly minted positions
- Stores each new tokenId in `TokenIdsSlot.tokenIds[]` (enumerable array)
- Activates the `UNIV4_LIQUIDITY` application flag on first position
- Enforces a maximum position count (128)

### Burn Cleanup
- Uses swap-and-pop to remove burned tokenId from storage array
- Deactivates `UNIV4_LIQUIDITY` application flag when last position is burned

### Hook Safety (Mint Only)
- Checks that the pool's V4 hook does NOT have `AFTER_ADD_LIQUIDITY_RETURNS_DELTA` or `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA` permissions
- These hooks could manipulate pool liquidity deltas, which is a security risk

---

## Supported Universal Router Commands

### Swaps (via `execute`)

| Command | Code | Input Encoding | Notes |
|---|---|---|---|
| `V3_SWAP_EXACT_IN` | `0x00` | `(recipient, amountIn, amountOutMin, path, payerIsUser)` | V3 multi-hop, path = packed `[token, fee, token, ...]` |
| `V3_SWAP_EXACT_OUT` | `0x01` | `(recipient, amountOut, amountInMax, path, payerIsUser)` | V3 exact output, path is reversed |
| `V2_SWAP_EXACT_IN` | `0x08` | `(recipient, amountIn, amountOutMin, path, payerIsUser)` | V2, path = `address[]` |
| `V2_SWAP_EXACT_OUT` | `0x09` | `(recipient, amountOut, amountInMax, path, payerIsUser)` | V2 exact output |
| `V4_SWAP` | `0x10` | `(actions, params[])` | V4 swap with nested actions (see below) |
| `EXECUTE_SUB_PLAN` | `0x21` | `(commands, inputs[])` | Recursive — decodes nested commands |

### Payment/Utility Commands

| Command | Code | Input Encoding | Notes |
|---|---|---|---|
| `SWEEP` | `0x04` | `(token, recipient, amountMin)` | Sweep leftover tokens from router |
| `TRANSFER` | `0x05` | `(token, recipient, value)` | Direct transfer |
| `PAY_PORTION` | `0x06` | `(token, recipient, bips)` | Pay a fraction |
| `WRAP_ETH` | `0x0b` | `(recipient, amount)` | ETH → WETH |
| `UNWRAP_WETH` | `0x0c` | `(recipient, amountMin)` | WETH → ETH |
| `BALANCE_CHECK_ERC20` | `0x0e` | N/A | No-op (staticcall in router) |

### Blocked Commands (revert immediately)

| Command | Code | Why Blocked |
|---|---|---|
| `PERMIT2_TRANSFER_FROM` | `0x02` | Direct Permit2 transfers bypass pool validation |
| `PERMIT2_PERMIT_BATCH` | `0x03` | Batch permits bypass pool approval flow |
| `PERMIT2_PERMIT` | `0x0a` | Single permit bypasses pool approval flow |
| `PERMIT2_TRANSFER_FROM_BATCH` | `0x0d` | Batch transfers bypass pool validation |
| `V3_POSITION_MANAGER_PERMIT` | `0x11` | V3 position management not supported |
| `V3_POSITION_MANAGER_CALL` | `0x12` | V3 position management not supported |
| `V4_POSITION_MANAGER_CALL` | `0x13` | Must use `modifyLiquidities` endpoint |

---

## Supported V4 Swap Actions (inside `V4_SWAP` command)

| Action | Code | Notes |
|---|---|---|
| `SWAP_EXACT_IN` | `0x07` | Multi-hop exact input via PathKey[] |
| `SWAP_EXACT_IN_SINGLE` | `0x06` | Single-pool exact input |
| `SWAP_EXACT_OUT` | `0x09` | Multi-hop exact output via PathKey[] |
| `SWAP_EXACT_OUT_SINGLE` | `0x08` | Single-pool exact output |
| `SETTLE` | `0x0b` | Settle a currency to V4 PoolManager |
| `SETTLE_ALL` | `0x0a` | Settle full balance of a currency |
| `TAKE` | `0x0e` | Take currency from V4 PoolManager to recipient |
| `TAKE_ALL` | `0x0f` | Take full balance of a currency |
| `TAKE_PORTION` | `0x10` | Take a fraction of a currency |

---

## Supported V4 Liquidity Actions (inside `modifyLiquidities`)

| Action | Code | Notes |
|---|---|---|
| `MINT_POSITION` | `0x02` | Creates new LP position, pool must be owner |
| `INCREASE_LIQUIDITY` | `0x00` | Adds liquidity to existing position |
| `DECREASE_LIQUIDITY` | `0x01` | Removes liquidity from existing position |
| `BURN_POSITION` | `0x03` | Burns position NFT (must have 0 liquidity) |
| `SETTLE_PAIR` | `0x0d` | Settles both currencies |
| `SETTLE` | `0x0b` | Settles one currency |
| `TAKE_PAIR` | `0x0c` | Takes both currencies to recipient |
| `TAKE` | `0x0e` | Takes one currency to recipient |
| `CLOSE_CURRENCY` | `0x11` | Settles or takes remaining balance |
| `CLEAR_OR_TAKE` | `0x12` | Takes if balance exceeds threshold |
| `SWEEP` | `0x14` | Sweeps leftover tokens |
| `WRAP` | `0x15` | ETH → WETH |
| `UNWRAP` | `0x16` | WETH → ETH |

### Blocked Liquidity Actions

| Action | Why |
|---|---|
| `INCREASE_LIQUIDITY_FROM_DELTAS` | Unpredictable amounts, cannot validate |
| `MINT_POSITION_FROM_DELTAS` | Unpredictable amounts, cannot validate |

---

## Transaction Encoding Guide

### TypeScript Helpers

Two planner classes are used for encoding (see `test/shared/`):

- **`RoutePlanner`** — Encodes Universal Router commands for `execute()`
- **`V4Planner`** — Encodes V4 actions for `V4_SWAP` command or `modifyLiquidities()`

### Example: V3 Exact-In Swap

```typescript
import { RoutePlanner, CommandType } from './shared/planner'
import { encodePath } from './shared/path'

// Swap WETH → USDC via V3 pool (0.3% fee)
const path = encodePath([WETH_ADDRESS, USDC_ADDRESS], [FeeAmount.MEDIUM])
const planner = new RoutePlanner()
planner.addCommand(CommandType.V3_SWAP_EXACT_IN, [
  poolAddress,          // recipient (must be pool address)
  parseEther("1"),      // amountIn
  parseUnits("1800", 6), // amountOutMin
  path,                  // packed path bytes
  true                   // payerIsUser (pool pays via Permit2)
])

// Encode as pool proxy call
const data = aUniswapRouterInterface.encodeFunctionData(
  'execute(bytes,bytes[],uint256)',
  [planner.commands, planner.inputs, deadline]
)
await poolOwner.sendTransaction({ to: poolAddress, data })
```

### Example: V4 Single-Pool Swap

```typescript
import { V4Planner, Actions } from './shared/v4Planner'
import { RoutePlanner, CommandType } from './shared/planner'

const poolKey = {
  currency0: ethers.constants.AddressZero, // native ETH
  currency1: WETH_ADDRESS,
  fee: 3000,
  tickSpacing: 60,
  hooks: ethers.constants.AddressZero
}

// Build V4 swap actions
const v4Planner = new V4Planner()
v4Planner.addAction(Actions.SWAP_EXACT_IN_SINGLE, [{
  poolKey,
  zeroForOne: true,
  amountIn: parseEther("1"),
  amountOutMinimum: parseEther("0.99"),
  hookData: '0x'
}])
v4Planner.addAction(Actions.SETTLE, [poolKey.currency0, parseEther("1"), true])
v4Planner.addAction(Actions.TAKE_ALL, [poolKey.currency1, 0])

// Wrap V4 actions in Universal Router command
const planner = new RoutePlanner()
planner.addCommand(CommandType.V4_SWAP, [v4Planner.actions, v4Planner.params])

const data = aUniswapRouterInterface.encodeFunctionData(
  'execute(bytes,bytes[],uint256)',
  [planner.commands, planner.inputs, deadline]
)
await poolOwner.sendTransaction({ to: poolAddress, data })
```

### Example: Mint V4 Liquidity Position

```typescript
import { V4Planner, Actions } from './shared/v4Planner'

const poolKey = {
  currency0: TOKEN_A,
  currency1: TOKEN_B,
  fee: 3000,
  tickSpacing: 60,
  hooks: ethers.constants.AddressZero
}

const v4Planner = new V4Planner()
v4Planner.addAction(Actions.MINT_POSITION, [
  poolKey,
  -887220,              // tickLower
  887220,               // tickUpper
  parseEther("100"),    // liquidity
  parseEther("50"),     // amount0Max
  parseEther("50"),     // amount1Max
  poolAddress,          // owner (MUST be pool address)
  '0x'                  // hookData
])
// CLOSE_CURRENCY handles settlement — settles what's owed, takes what's surplus
v4Planner.addAction(Actions.CLOSE_CURRENCY, [poolKey.currency0])
v4Planner.addAction(Actions.CLOSE_CURRENCY, [poolKey.currency1])

const data = aUniswapRouterInterface.encodeFunctionData(
  'modifyLiquidities',
  [v4Planner.finalize(), deadline]
)
await poolOwner.sendTransaction({ to: poolAddress, data })
```

### Example: V2 Swap Exact-In (Native ETH)

```typescript
const planner = new RoutePlanner()
planner.addCommand(CommandType.V2_SWAP_EXACT_IN, [
  poolAddress,                    // recipient
  parseEther("1"),                // amountIn
  parseUnits("1800", 6),          // amountOutMin
  [AddressZero, USDC_ADDRESS],    // path (AddressZero = native ETH)
  true                            // payerIsUser
])

const data = aUniswapRouterInterface.encodeFunctionData(
  'execute(bytes,bytes[],uint256)',
  [planner.commands, planner.inputs, deadline]
)
// value is auto-calculated by decoder (1 ETH for native input)
await poolOwner.sendTransaction({ to: poolAddress, data })
```

---

## Common Pitfalls

### 1. Recipient Must Be Pool or Router
Every recipient in the calldata must resolve to the pool address, `MSG_SENDER`, or `ADDRESS_THIS`. Using any other address will revert with `RecipientNotSmartPoolOrRouter`.

### 2. Output Tokens Need Oracle Price Feeds
Any token appearing as `tokensOut` must have an active price feed registered in the EOracle extension, otherwise the transaction reverts with `TokenPriceFeedDoesNotExist`. Register price feeds before trading new token pairs.

### 3. Native ETH Value Is Auto-Calculated
The decoder sums up all native ETH amounts from the commands (e.g., `WRAP_ETH` amount, V2 native input, V4 native settlements). The adapter sends this value with the forwarded call. You do NOT send ETH value manually — the pool's existing ETH balance is used.

### 4. Permit2 Approvals Are Automatic
The adapter handles all token approvals via Permit2. Pool owners never need to call `approve` or `permit` directly. Block-scoped expiration (expiration = 0) ensures approvals don't persist.

### 5. Position Ownership
For `INCREASE_LIQUIDITY`, `DECREASE_LIQUIDITY`, and `BURN_POSITION`, the tokenId must be tracked in the pool's storage (created via a prior `MINT_POSITION` through this adapter). Operating on positions not owned by the pool reverts with `PositionOwner`.

### 6. Hook Restrictions
V4 positions with hooks that have `AFTER_ADD_LIQUIDITY_RETURNS_DELTA` or `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA` permissions are blocked on mint. These hooks can manipulate pool deltas.

### 7. Cannot Mint and Increase Same Position in One Call
The decoder runs before the call is forwarded, so a newly minted position's tokenId is not yet known. Mint and increase operations on the same position must be separate transactions.

### 8. `MINT_POSITION` Owner Must Be Pool Address
The `owner` parameter in `MINT_POSITION` is validated as a recipient. It must be `poolAddress` (i.e., `address(this)` in delegatecall context).

### 9. V3 Path Encoding
V3 paths are packed bytes: `[tokenA (20 bytes) | fee (3 bytes) | tokenB (20 bytes) | fee (3 bytes) | tokenC (20 bytes)]`. For exact-out, the path is **reversed** — first token in path bytes is the output token.

### 10. V2 Path Direction
V2 paths are `address[]`. For both exact-in AND exact-out, `path[0]` is always the input token and `path[last]` is always the output token (unlike V3 where exact-out reverses the path).
