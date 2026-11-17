# Developer Guide

This guide covers patterns for adding new components to Rigoblock and common pitfalls to avoid.

## Storage pattern

All storage uses the ERC-7201 namespaced pattern with dot notation:

```solidity
// In MixinConstants.sol - use dots to separate namespace components
bytes32 internal constant _VIRTUAL_SUPPLY_SLOT =
    bytes32(uint256(keccak256("pool.proxy.virtual.supply")) - 1);

// NOT this - avoid mixed dots and camelCase
bytes32 internal constant _WRONG_SLOT =
    bytes32(uint256(keccak256("pool.proxy.virtualSupply")) - 1); // ❌

// In MixinStorage.sol constructor - assert the slot calculation
assert(_VIRTUAL_SUPPLY_SLOT == bytes32(uint256(keccak256("pool.proxy.virtual.supply")) - 1));

// Access in contracts
function _getValue(address key) private view returns (uint256 value) {
    bytes32 slot = _VIRTUAL_SUPPLY_SLOT;
    assembly { value := sload(slot) }
}

function _setValue(address key, uint256 value) private {
    bytes32 slot = _VIRTUAL_SUPPLY_SLOT.deriveMapping(key);
    assembly { sstore(slot, value) }
}
```

### Adding new storage

1. Define the slot in `MixinConstants.sol` using dot notation.
2. Assert the slot in `MixinStorage.sol` constructor.
3. Access via assembly with `deriveMapping()` for nested mappings.

Never reorder or remove existing storage variables.

## Common operations

### Read pool state

```solidity
import {StorageLib} from "../../libraries/StorageLib.sol";

Pool memory pool = StorageLib.pool();
address baseToken = pool.baseToken;
address owner = pool.owner;
uint8 decimals = pool.decimals;
```

### Update NAV

```solidity
// ALWAYS update before reading if you need current NAV
ISmartPoolActions(address(this)).updateUnitaryValue();

ISmartPoolState.PoolTokens memory poolTokens =
    ISmartPoolState(address(this)).getPoolTokens();
uint256 currentNav = poolTokens.unitaryValue;
```

### Safe token operations

```solidity
using SafeTransferLib for address;

token.safeTransfer(to, amount);
token.safeTransferFrom(from, to, amount);
token.safeApprove(spender, amount); // Handles USDT-style tokens
```

### Check price feed

```solidity
require(
    IEOracle(address(this)).hasPriceFeed(token),
    "Token must have price feed"
);
```

### Convert token amounts

```solidity
int256 baseAmount = IEOracle(address(this)).convertTokenAmount(
    inputToken,
    inputAmount.toInt256(),
    baseToken
);
```

## Token approval patterns for external protocol integrations

**CRITICAL**: The approval pattern must match the target protocol's scoping mechanism. Verify the target's token flow before writing approval code.

### Pattern 1 — Target uses Permit2 (e.g., Uniswap via AUniswapRouter)

```solidity
// Layer 1: One-time persistent ERC20 → Permit2 (checked with threshold)
if (IERC20(token).allowance(address(this), address(_permit2)) < type(uint96).max) {
    token.safeApprove(address(_permit2), type(uint256).max);
}
// Layer 2: Per-call Permit2.approve with block-scoped expiration
_permit2.approve(token, target, type(uint160).max, 0); // expiration=0 → current block only
```

### Pattern 2 — Target does NOT use Permit2 (e.g., 0x AllowanceHolder via A0xRouter)

```solidity
// Per-call: approve exact amount before call, reset to 1 after success
token.safeApprove(address(target), amount);

try target.exec{value: value}(...) returns (bytes memory result) {
    token.safeApprove(address(target), 1); // reset to 1 (keeps slot warm for gas savings)
    return result;
} catch { ... } // revert unwinds the approval automatically
```

### How to determine which pattern to use

1. Read the target protocol's docs for their token transfer mechanism.
2. If the target supports Permit2 → Pattern 1 (persistent ERC20 + per-call Permit2.approve).
3. If the target uses standard ERC20 `transferFrom` → Pattern 2 (per-call approve + reset).
4. ALWAYS use `safeApprove` for USDT compatibility.
5. For native ETH: forward via `{value: value}` — no ERC20 approval needed.

### Approval reset to 1, not 0

- Resetting to 0 clears storage → next swap pays 20 000 gas (zero → non-zero SSTORE).
- Resetting to 1 keeps the slot warm → next swap pays 5 000 gas (non-zero → non-zero SSTORE).
- Always reset to 1 unless there's a specific reason to fully clear.

### Native ETH handling in adapters

- **NEVER use `msg.value`** to forward ETH in adapter calls. The adapter runs via delegatecall, so `msg.value` comes from the CALLER, not the pool.
- The pool is the vault; derive the ETH value from calldata parameters.
- Example: `uint256 value = token.isAddressZero() ? amount : 0;`
- Then: `target.exec{value: value}(...)` — sends from the pool's own balance.
- For `InsufficientNativeBalance` check: compare the derived `value` to `address(this).balance`.

### Testing requirements for new integrations

- Test all swap directions: ETH→Token, Token→ETH, Token→Token.
- Test with USDT (special approval behavior).
- Test on fork with real deployed contracts (not just mocks).
- Verify allowance is 1 (not 0) after each successful call (for Pattern 2).
- Verify revert unwinds approval state correctly.
- Verify ETH swaps use pool balance, NOT caller's `msg.value`.

## Adding a new adapter

1. Create `contracts/protocol/extensions/adapters/YourAdapter.sol`.
2. Create an interface in `adapters/interfaces/IYourAdapter.sol`.
3. Add an `onlyDelegateCall` modifier.
4. Store `_IMPLEMENTATION = address(this)` in the constructor.
5. Use `StorageLib` for pool storage access.
6. Add methods to `Authority.sol` via governance.

When wrapping an external protocol, the adapter interface must expose the **same function signatures** as the underlying protocol interface. Copy the exact parameter list; do not wrap flat params into a struct or omit params. If a parameter must be overridden for security (e.g., `address receiver` that must always be `address(this)`), keep it in the interface but leave the variable name blank and ignore the caller-supplied value in the implementation. Document the override in the NatSpec.

## Adding a new extension

1. Create `contracts/protocol/extensions/YourExtension.sol`.
2. Create an interface in `extensions/adapters/interfaces/IYourExtension.sol`.
3. Take chain-specific params in the constructor and store them as `immutable`.
4. Add the selector to `ExtensionsMap.sol` with a `shouldDelegatecall` flag.
5. Update `ExtensionsMapDeployer.sol` to pass params.
6. Update `DeploymentParams.sol` types.
7. Deploy with a new salt (see [DEPLOYMENT.md](./DEPLOYMENT.md)).

## Gas optimization tips

- Use `immutable` for chain-specific constants (e.g., `acrossSpokePool`, `wrappedNative`).
- Use transient storage for temporary values (`ReentrancyGuardTransient`).
- Batch read storage into memory structs.
- Cache storage reads in loops.

## Documentation

- NatSpec all public/external functions.
- Use `@inheritdoc` for interface implementations.
- Keep inline code comments strictly minimal: only what is needed to understand non-obvious "why".
- Design rationale, audit responses, and known limitations belong in `/docs/`, not in source code.
- Do not add verbose NatSpec justifying design decisions or mentioning future features.

### Where to save documentation

- General docs → `/docs/`
- Protocol-specific (Across, Uniswap, etc.) → `/docs/<protocol>/`
- Working documents → update existing files, don't create many small files

Create or update a single comprehensive document, then move it to the appropriate `/docs/` subfolder when complete.

## Common pitfalls to avoid

1. **Adding storage to extensions/adapters** — they run in pool context, so use pool storage.
2. **Direct calls to extensions/adapters** — they are always called via delegatecall.
3. **Adapter access control misunderstanding** — there is NO `onlyPoolOwner` modifier in adapter code. Write-mode gating lives in `MixinFallback` (`shouldDelegatecall = msg.sender == pool().owner`); non-owners are routed via `staticcall` so state writes revert. Extensions are always delegatecalled, so they need explicit `msg.sender` checks when caller restriction is required.
4. **Breaking storage layout** — never reorder or modify existing storage.
5. **Reading stale NAV** — call `updateUnitaryValue()` first if you need the current value.
6. **Assuming same addresses across chains** — extensions are chain-specific.
7. **Missing price feed checks** — always verify `hasPriceFeed()` for new tokens.
8. **Unsafe token operations** — use `SafeTransferLib` for USDT compatibility.
9. **Not testing on forks** — integration tests should use actual deployed contracts.
10. **Ignoring virtual supply** — cross-chain transfers must maintain NAV integrity via VS.
11. **Changing `Constants.sol` addresses** — the addresses in `Constants.sol` are the correct deployed addresses for fork testing. Never change them without verification; always import from `Constants.sol`.
12. **Duplicating storage slots or constants** — define them in a single authoritative location and reference them. If a value must be duplicated for technical reasons (e.g., `immutable` in constructor), document which is the source of truth.
13. **Wrong approval pattern for external protocols** — verify whether the target uses Permit2 or standard ERC20 `transferFrom` before writing approval code.
14. **Using `msg.value` in adapters** — derive ETH value from calldata params and forward from the pool's own balance.
15. **Resetting approval to 0** — reset to 1 to keep the storage slot warm.
16. **Using inline assembly unnecessarily** — prefer `abi.decode`, Solidity calldata slicing, and `IInterface.functionName.selector`. Use assembly only for raw error propagation, extracting `bytes4` from `bytes memory`, and ERC-7201 storage slot access.
17. **Using `bytes4(keccak256(...))` for selectors** — always use `IInterface.functionName.selector`. The only exception is overloaded functions, where Solidity cannot apply `.selector`; in that case document the expected 4-byte value.
18. **Low-level calls in tests** — use typed interface calls instead of `target.call(...)`. Use `vm.expectRevert` for expected reverts.
19. **App activation** — call `StorageLib.activeApplications().storeApplication(...)` ONLY when the adapter creates an external position that must be valued by `EApps`. Pure swaps, bridges, or other flows that leave no on-chain position do not need activation.
20. **Test failures after audit fixes** — a failing test is a signal, not noise. Understand what it was asserting, why the fix changed behavior, and whether the test or the fix is wrong before removing or rewriting it.
21. **Applying audit findings blindly** — run the full test suite, verify through protocol documentation that the fix cannot block any legitimate path, and document any "not fixed" or "by-design" disposition.
22. **Named mapping variables** — all new or modified mappings must use named key and value parameters (`mapping(KeyType key => ValueType value)`).
23. **Skipping `forge clean`** — always run `forge clean` before `forge build`/`forge test` after switching branches or updating submodules to avoid spurious failures from mismatched CBOR metadata tails.
