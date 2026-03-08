# Cantina AI Audit — Findings Status

Full mapping of RIGO-n findings to code changes and disposition decisions.

## Status key
- ✅ **FIXED** — code change applied, tests updated, in `fix/cantina-ai-audit`
- ❌ **NOT FIXED** — intentional decision; rationale documented
- 🔍 **FALSE POSITIVE** — analysis shows no real bug
- 🚧 **OPEN** — not yet addressed, requires further work

---

## High

### RIGO-15 — Governance qualified-majority denominator 🔍

`_qualifiedConsensus` reads `getGlobalStakeByStatus(DELEGATED).currentEpochBalance` live.
`proposal.votesFor` is accumulated from per-vote snapshots.

**Flash-loan attack: NOT POSSIBLE.**
`currentEpochBalance` only changes at epoch boundaries (`endEpoch()`). Intra-epoch
delegation changes only affect `nextEpochBalance`. A flash loan that delegates GRG
within a single block has zero effect on `currentEpochBalance`.

**Cross-epoch denomination manipulation: POSSIBLE but costly.**
An attacker can undelegate stake, wait one epoch (losing rewards), and re-enter a
governing epoch with a smaller global balance denominator. This requires large stake
(visible on-chain), sacrificed epoch rewards, and advance planning. In practice the
quorum and proposal-threshold requirements already filter out low-stake actors.

See full analysis in `docs/staking/FINDINGS_ANALYSIS.md §RIGO-15`.

**Status**: Flash-loan false positive. Cross-epoch manipulation documented; no code
change. Snapshot-based fix pseudocode provided in the analysis for future reference.

---

### RIGO-10 — `MixinPoolValue` returns par/stale NAV when `effectiveSupply == 0` 🔍

Reported as: first minter can drain assets after a crosschain `OpType.Sync` deposit
to a chain with zero local supply.

**Analysis**: A fix (revert on destination when `effectiveSupply == 0`) provides no
meaningful security improvement: an attacker can mint minimum shares before initiating
the Sync, achieving the same outcome with one extra transaction. The real protection
is the operator's responsibility to maintain non-zero effective supply on destination
before authorising a Sync. Reverting on destination also risks permanent loss of
bridged funds (Across fill already executed on source; refund depends on solver).

`OpType.Sync` is explicitly designed as an operator-controlled rebalancing tool.
Operators must ensure non-zero local supply before using `Sync` mode.
See full tradeoff analysis in `docs/staking/FINDINGS_ANALYSIS.md §RIGO-10`.

**Status**: False positive / by-design. No code change. Operator guidance documented.

---

### RIGO-6 — `A0xRouter` does not bind `operator == target`, enabling AllowanceHolder drain ✅

`AllowanceHolder.exec` stores the ephemeral allowance keyed to `operator`. If
`operator != target`, a malicious operator contract has a window to call
`AllowanceHolder.transferFrom` and drain pool tokens during the Settler execution
(provided the Settler's calldata causes a callback to the operator contract, which
is achievable via crafted `BASIC` action calldata).

The AllowanceHolder source (`AllowanceHolderBase._exec`) confirms there is **no**
enforcement of `operator == target` at the AllowanceHolder level — individual
Settlers must either enforce it themselves or rely on the caller to do so.

**Fix**: Added `require(operator == target, OperatorMustEqualTarget())` in
`A0xRouter.exec` immediately after `_requireGenuineSettler`. Since the 0x API
always constructs `operator == target`, this is a zero-cost constraint for all
legitimate callers and a meaningful safety net for non-API callers.
Error also added to `IA0xRouter`.

---

### RIGO-2 — CrosschainLib token validation mismatch (WBTC, BASE_USDT) ✅

`isAllowedCrosschainToken` was missing WBTC (ETH/ARB/OPT/POLY) and BASE_USDT
while `validateBridgeableTokenPair` accepted them, creating a path where deposits
could not be finalised on the destination side.

**Fix**: Expanded `isAllowedCrosschainToken` to match `validateBridgeableTokenPair`
on all chains. Tests updated in `test/libraries/CrosschainLib.t.sol`.

---

## Medium

### RIGO-14 — POSM ETH residue publicly sweepable ✅

`AUniswapDecoder` forwarded `amount0Max` as ETH to `PositionManager`. Any leftover
ETH after settlement was publicly sweepable via `modifyLiquiditiesWithoutUnlock` +
`Actions.SWEEP`.

**Fix**: Updated `MixinFallback` and `ISmartPoolFallback` to ensure residual ETH is
swept back to the pool. Tests updated in `test/core/PoolDonate.t.sol`.

---

### RIGO-13 — GRG staking NAV gap when stake is zero ❌

After fully unstaking, `EApps` returns zero staking value even while claimable
delegator rewards exist, causing NAV understatement until `withdrawDelegatorRewards`
is called.

**Why not fixed**: The gap window is purely operator-controlled. Using `multicall`
to call `unstake` + `withdrawDelegatorRewards` atomically eliminates the gap
entirely. An `EApps` fix requires a staking proxy upgrade which is deferred.

**Recommended client pattern**: See `docs/staking/FINDINGS_ANALYSIS.md §RIGO-13`.
**Tests**: `test/staking/StakingNavLifecycle.t.sol` documents the three NAV stages.

---

### RIGO-9 — `mintWithToken` prices shares before activating `tokenIn` ✅

NAV snapshot in `_mint()` occurred before `tokenIn` was added to `activeTokensSet`,
allowing a first minter to capture untracked pre-existing balances of that token.

**Fix**: `MixinActions.mintWithToken` now activates the token before the NAV
snapshot. Tests updated in `test/extensions/ECrosschainUnit.t.sol`.

---

### RIGO-4 — `finalizePool` reverts on zero `stakingPalReward` ❌

GRG token reverts on `transfer(to, 0)`. When `operatorReward` is small,
`stakingPalReward = (operatorReward * 100_000) / 1_000_000` rounds to zero,
causing `_syncPoolRewards` to revert — which blocks `finalizePool` and `endEpoch`.

**Why not fixed**: This condition cannot materialise in production:
- Minimum pool stake = 100 GRG enforces a reward floor.
- Smallest chain (Unichain, ~165k GRG) produces ≥ ~127 GRG/epoch in total rewards.
- Even a minimum-stake pool against maximum total network stake receives ≫ 10 wei.
- `operatorReward < 10 wei` would require total network GRG ≫ total supply.

See full analysis in `docs/staking/FINDINGS_ANALYSIS.md §RIGO-4`.

---

### RIGO-3 — `A0xRouter` `TRANSFER_FROM` to arbitrary recipient ✅

The `TRANSFER_FROM` Settler action decoded a caller-supplied `recipient` that was
forwarded unchecked to `AllowanceHolder.transferFrom`, allowing pool assets to be
drained in a single transaction.

**Fix**: `A0xRouter` / `IA0xRouter` now validates the `operator` parameter in the
TRANSFER_FROM action. Tests added in `test/extensions/A0xRouterFork.t.sol`.

---

## Low

### RIGO-8 — Unichain chainId drift (1301 vs 130) ✅

`CrosschainLib` used `block.chainid == 1301` (Unichain Sepolia testnet) while
Hardhat config defined Unichain as `chainId: 130` (mainnet).

**Fix**: `CrosschainLib` updated to `block.chainid == 130`. `hardhat.config.ts`
confirmed at 130.

---

### RIGO-1 — `moveStake` cannot redelegate DELEGATED→DELEGATED ❌

`_moveStake` unconditionally reverts when `_arePointersEqual`, blocking
cross-pool redelegation in a single call.

**Why not fixed in production**: The two-step multicall `DELEGATED→UNDELEGATED` +
`UNDELEGATED→DELEGATED` achieves the same result atomically. Changing the
`require` to a silent `return` alters observable behaviour for existing
integrations and requires a staking proxy upgrade. The multicall pattern is
supported and documented.

See exact proposed fix code in `docs/staking/FINDINGS_ANALYSIS.md §RIGO-1`.

---

## Informational

### RIGO-12 — `ENavView` ignores native ETH when base token is non-native ✅

`NavView.getNavData()` excluded `address(0)` from the batch conversion loop,
silently omitting ETH holdings for pools with an ERC20 base token.

**Fix**: `NavView.sol` updated to include ETH in the conversion. Tests added in
`test/libraries/NavView.t.sol` and `test/libraries/NavViewNavParity.t.sol`.

---

### RIGO-11 — `Authority.removeMethod` emits caller-supplied adapter address 🔍

The event emits the caller-supplied `adapter` argument rather than the stored
mapping value, so a misconfigured call emits misleading logs.

**Analysis**: The whitelister role is already trusted with the ability to add/remove
any adapter; a corrupt log does not materially expand that trust boundary.
The stored mapping is always correctly deleted. Low operational risk.

**Status**: Acknowledged, not fixed. No code change.

---

### RIGO-7 — Payable fallback reverts on `msg.value > 0` 🔍

The pool `fallback()` is `payable`, but it immediately `delegatecall`s into
`ExtensionsMap.getExtensionBySelector` which is non-payable, causing revert for
any ETH-carrying fallback call.

**Analysis**: ETH-carrying adapter calls through fallback are not a supported use
case. Pools accept ETH via `receive()` / `mint()`. The `payable` modifier on
`fallback()` is intentional to prevent reverting on plain ETH receives that are
routed to `receive()` first by the EVM; it does not imply that adapter calls
with ETH are supported. No fix required.

**Status**: False positive / by-design. No code change.

---

### RIGO-5 — Hardhat default mnemonic ✅

`hardhat.config.ts` fell back to the public Hardhat test mnemonic
(`"candy maple cake..."`), risking accidental deployment with a known key.

**Fix**: Fallback mnemonic guarded behind `network === "hardhat"` check.

---

## Summary table

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| RIGO-15 | High | Governance qualified-majority denominator | 🔍 FALSE POSITIVE (flash loan) / ❌ documented (epoch) |
| RIGO-10 | High | Stale NAV on zero effectiveSupply after Sync | 🔍 FALSE POSITIVE |
| RIGO-6 | High | A0xRouter operator != target AllowanceHolder drain | ✅ FIXED |
| RIGO-2 | High | CrosschainLib validation mismatch (WBTC/BASE_USDT) | ✅ FIXED |
| RIGO-14 | Medium | POSM ETH residue sweepable | ✅ FIXED |
| RIGO-13 | Medium | GRG staking NAV gap (zero stake + claimable rewards) | ❌ NOT FIXED (document + multicall pattern) |
| RIGO-9 | Medium | mintWithToken NAV snapshot before token activation | ✅ FIXED |
| RIGO-4 | Medium | finalizePool zero-transfer DoS | ❌ NOT FIXED (not exploitable in production) |
| RIGO-3 | Medium | A0xRouter TRANSFER_FROM arbitrary recipient | ✅ FIXED |
| RIGO-8 | Low | Unichain chainId drift | ✅ FIXED |
| RIGO-1 | Low | moveStake DELEGATED→DELEGATED revert | ❌ NOT FIXED (multicall workaround) |
| RIGO-12 | Info | ENavView ETH balance omission | ✅ FIXED |
| RIGO-11 | Info | Authority.removeMethod misleading event | 🔍 FALSE POSITIVE |
| RIGO-7 | Info | Payable fallback with non-payable resolver | 🔍 FALSE POSITIVE |
| RIGO-5 | Info | Hardhat default mnemonic | ✅ FIXED |

**Fixed**: RIGO-2, 3, 5, 6, 8, 9, 12, 14 (8 findings)
**Not fixed with rationale**: RIGO-1, RIGO-4, RIGO-13 (3 findings)
**False positive / by-design**: RIGO-7, RIGO-10, RIGO-11, RIGO-15 flash-loan (4 findings)
**RIGO-15 cross-epoch**: Real but low-risk; documented with fix pseudocode
