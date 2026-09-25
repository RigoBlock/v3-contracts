# Hyperliquid Integration

The Rigoblock Hyperliquid adapter (`AHyperliquid`) exposes the canonical `ICoreWriter` and `ICoreDepositWallet` interfaces so Rigoblock smart pools can interact with Hyperliquid Core as a **USDC-only perps account**.

## Deposit flow

Deposits are routed straight to the Core perp dex via `CoreDepositWallet.deposit(..., destinationDex = 0)`. The adapter only accepts `destinationDex == 0`; spot deposits are rejected because the pool has no price feed for Hyperliquid spot markets and only manages USDC.

## Withdrawal flow

Withdrawing back to HyperEVM is operator-driven and necessarily touches the Core spot account:

1. Move USDC from Core perp margin to Core spot with `USD_CLASS_TRANSFER(toPerp = false)`.
2. Bridge from Core spot to HyperEVM with `SPOT_SEND` targeting the USDC system address.

There is no direct perp-to-EVM bridge in CoreWriter, so both steps are required. Spot-to-perp transfers (`toPerp = true`) are rejected because the adapter is perps-only and does not track spot balances as active NAV tokens.

## Asset restrictions

- Only core perp assets (`assetId < 10_000`) are accepted for limit orders and cancels.
- Outcome markets (`assetId >= 100_000_000`) are rejected. See [`OUTCOME_MARKETS.md`](./OUTCOME_MARKETS.md) for the saved reference implementation and why it was deferred.
- Only USDC (`HLConstants.USDC_TOKEN_INDEX`) is allowed for spot sends.

## NAV / settlement gap

HyperCore state and HyperEVM state update in a fixed sequence within each L1 block, per the [Hyperliquid interaction-timings docs](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interaction-timings): the L1 block is built, the EVM block is built, EVM→Core transfers are processed, and CoreWriter actions are processed — all within the same L1 block. Two consequences matter for NAV accounting:

- **Transfers HyperEVM → HyperCore** (pool deposits) are processed **immediately after the EVM block is built**, so the Core precompiles reflect a deposit starting from the **next EVM block** — even if the L1 block has not advanced.
- **Transfers HyperCore → HyperEVM** (spot-send wallet credits) are queued on the L1 until the **next HyperEVM block**, so they also land within one EVM block.

(Terminology: "L1 block" is the HyperCore block — the HyperBFT consensus chain that runs the order book and spot ledger; HyperEVM is the EVM execution environment on the same validator set. The L1 block number precompile reports which HyperCore block the other read precompiles reflect.)

`HyperliquidLib` therefore tracks in-flight amounts against a **composite key** — high 128 bits = L1 block number, low 128 bits = EVM block number — and expires them at the **next EVM block**: within the deposit's own EVM block the precompile lags and the in-flight add-back keeps NAV exact; from the next EVM block on the precompile is guaranteed to reflect non-delayed transfers, so keeping the add-back any longer would double-count. This mirrors the composite-key scheme used by audited HyperEVM integrations. It records an in-flight USDC adjustment on deposits and a cumulative `SPOT_SEND` counter on withdrawals (reset on every new composite block). The `SPOT_SEND` counter is used only inside `_spotSend` to prevent requesting more than the available Core spot balance within one EVM block; it is not subtracted from NAV, so withdrawals do not deflate the pool value.

Because the in-flight adjustment keeps the in-block NAV self-consistent, **same-block transactions are never blocked**: a mint, burn, donation, or NAV read landing in the same EVM block as a deposit or spot-send sees the correct value. From the **next EVM block on**, the in-flight amount is dropped and the settlement lock (`HyperliquidLib.assertNavUnlocked`) reverts NAV-sensitive operations until `_SETTLEMENT_WINDOW` after the action's timestamp.

The lock is asserted in the `HYPERLIQUID` branch of `EApps` — every NAV write reaches application balances through `EApps`, so any method that writes NAV is locked by default (fail-closed), including `purgeInactiveTokensAndApps`, whose internal `try/catch` only catches `Error(string)` and therefore lets the custom `NavLocked` error propagate. There is a **single explicit exemption**: `updateUnitaryValue`, which is NAV-neutral and is the path used by crosschain `donate` (`ECrosschain` routes both donation phases through it). The exemption is implemented as a transient-storage flag (`TransientStorage.setNavLockExempt`) set around `_updateNav` inside `updateUnitaryValue` and cleared before it returns, so it cannot leak into a batched mint/burn in the same transaction; transient storage also clears at transaction end, so it can never leak across transactions. Because the flag only suppresses `assertNavUnlocked` and leaves the balance read untouched, the composite-block in-flight semantics apply unchanged inside the exempt window: both donation phases observe the identical treatment of a same-block action (same composite → same add-back), and an exempt read in a later block sees the precompile with the in-flight amount already dropped. `_updateNav` performs no state-changing external calls while the flag is set, so the exempt window is not reentrant. This keeps cross-chain transfers unaffected by the lock (see issue #959). Perp trading actions (limit orders, cancels, USD-class transfers) do not trigger the lock, because they do not move funds between HyperCore and the EVM-side pool wallet. Off-chain views (`NavView` / `ENavView.getNavDataView`) use the unguarded balance reader, so the nav shield can still read a potentially stale NAV and enforce its own policy. Because the Hyperliquid balance path is only reached when the `HYPERLIQUID` application bit is active, the lock costs nothing on chains where Hyperliquid is not active.

### Why `_SETTLEMENT_WINDOW`?

Per the interaction-timings sequence, non-delayed transfers (deposits, spot sends) are fully reflected on both sides by the **next EVM block**. `_SETTLEMENT_WINDOW` (`HyperliquidLib`) is a conservative time lock on top of that guarantee: it covers what the next-EVM-block guarantee does not — delayed CoreWriter actions (orders and vault transfers are delayed a few seconds on-chain, though they do not arm the lock), small/big block sequencing effects, and any processing latency not covered by the published timing. A value of zero would leave only the same-block guards and must therefore never be set. The current value is a policy choice, not a published Hyperliquid SLA, and can be adjusted by a future implementation upgrade if real-world latency data justifies it.

**Operator responsibility (big blocks).** The pool operator is expected to use the default small-block setting for HyperEVM pool transactions (deposit, spot-send, and any NAV-sensitive call are all well under the 3M gas small-block limit). If an operator were to enable big blocks (`usingBigBlocks: true`), their transactions could land in a 60-second big block, which would extend the effective stale-NAV period beyond `_SETTLEMENT_WINDOW`. Checking and choosing the block setting is the operator's own responsibility.

**Known, accepted limitation.** An operator who deliberately uses big-block settings (or otherwise games block timing) could transact against a NAV that is stale beyond the settlement window. This possibility is recognized and accepted: it requires the operator to act against their own pool's interest, it cannot be exploited by third parties, and **it is not a valid bug-bounty finding**. Off-chain agents that need to know whether the settlement window is open can read the `lastActionTimestamp` field in `HyperliquidData` directly from the pool storage slot and compare it to the current `block.timestamp`.

Operators and users should still avoid relying on same-block NAV for economically consequential operations outside the pool (e.g. pricing the pool token off-chain), because delayed actions (notably limit-order fills) can leave Core value stale beyond the on-chain guard.

### Audit findings disposition (settlement lock)

Three audit-agent findings on `HyperliquidLib` were dispositioned as **accepted by design**. They are recorded here so future reports of the same observations can be triaged against this analysis.

**1. Unrecorded marketable orders can leave NAV writable against stale Core value — accepted.** See [Limit orders and same-block fills](#limit-orders-and-same-block-fills): orders deliberately do not arm the lock, the path is operator-gated, and a time lock could not guarantee freshness for delayed order effects anyway.

**2. A later Core action discards the earlier block's in-flight amount and re-enables same-block NAV — accepted; matches the audited reference scheme.** In the documented interaction-timings sequence, a deposit's Core credit is visible from the next EVM block, so resetting the in-flight amount at exactly that point is the *correct norm behavior*: keeping the add-back any longer would double-count the deposit as soon as the precompile catches up, which is guaranteed within the same L1 block. The harmful scenario requires all of: (a) precompile lag beyond one EVM block for a *non-delayed* transfer — which the interaction-timings sequence excludes (delayed actions are CoreWriter effects, not EVM→Core transfers); (b) a second operator action in the next block; and (c) the operator then transacting against their own pool in that block. It is operator-gated, bounded to a single block, and falls under the accepted operator-responsibility limitation. The reset-on-new-composite semantics is the one used by audited third-party implementations of the same composite-key scheme; deviating from it would trade a hypothetical operator-only edge case for a guaranteed double-count in the norm.

**3. The fixed `_SETTLEMENT_WINDOW` can expire while Core reader balances are still stale — accepted; snapshot-and-serve was evaluated and rejected.** A fixed time window cannot prove Core inclusion — that is true by construction, and the window is conservative defense-in-depth on top of the next-EVM-block guarantee, not the primary guard (the in-flight add-back is). The suggested alternative — snapshot NAV at action time and serve the snapshot during the window — was rejected: it replaces "deny while uncertain" with "execute against a knowingly stale NAV for the entire window", so `mint`/`burn` would succeed at stale prices instead of reverting; it has the identical overwrite problem (a snapshot taken at a later action can itself miss the earlier unsettled action) but latent for the whole window instead of one block; and it would require Hyperliquid-specific snapshot plumbing inside core NAV storage, which the minimal-core design explicitly avoids. Extending the lock to cover these cases (e.g. blocking the operator's action block whenever a prior action is unsettled) was also rejected: it reintroduces the same-block `mint`/`burn` DOS this design set out to eliminate, since the operator's dust action in the same block as a user's `mint` would lock it again.

Related mechanics that are *not* findings: deposit → limit order in the next block does not clear anything (orders never call `recordAction`; the in-flight amount only ever applies in its own composite block, and the deposit is visible in the precompile by then anyway); deposit → withdrawal request in the next block clears the in-flight amount exactly when the deposit becomes visible — the norm-correct behavior — and a spot-send needs no in-flight add-back of its own because it moves no value at request time.

### Deposit vs withdrawal asymmetry

Deposits and withdrawals move value in opposite directions and are handled differently:

- **Deposit** (`AHyperliquid.deposit`): USDC leaves the pool's EVM wallet immediately (the transfer is visible in the same transaction), but the Core balance precompile does not reflect the credit until HyperCore processes EVM→Core transfers — immediately after the deposit's EVM block is built. Without an adjustment, NAV would drop by the deposit amount for the rest of the block even though the pool's total wealth is unchanged. `recordAction(amount, false)` therefore stores an **in-flight amount** that `getHyperliquidBalances` adds back within the same EVM block only. From the next EVM block on the precompile reflects the deposit, so the in-flight amount is discarded (and reset in storage by the next `recordAction` in a new composite block).
- **Withdrawal** (`sendRawAction` with `SPOT_SEND`): the EVM transaction only *requests* the withdrawal, and `_spotSend` forces the destination to be the pool's own system address, so the transfer can only ever move funds from the pool's Core account to the pool's EVM wallet — NAV-neutral at every stage. Within the same EVM block nothing has moved on either side — the CoreWriter action is only queued when the block is built — and the counted balance still belongs to the pool, so NAV is exact as computed and no in-flight adjustment is needed (subtracting it here would understate NAV). The request is tracked only as a cumulative `pendingSpotSend` counter, used inside `_spotSend` to cap same-block withdrawal requests at the available Core spot balance. See the timeline below for the exact per-block states.

#### Withdrawal settlement timeline

Concrete example: pool owns 200 USDC — 100 in the EVM wallet, 100 in the Core spot account — and the operator requests a 50 USDC spot-send at EVM block N, while the HyperCore L1 block is L.

| Stage | EVM wallet (readable on-chain) | Core spot precompile (readable on-chain) | NAV as computed | Exact? |
|---|---|---|---|---|
| EVM block N (request, L1 block L): `sendRawAction(SPOT_SEND, 50)` executes | 100 | 100 | 200 | yes — nothing has moved on either layer; the CoreWriter action is only queued when the block is built |
| EVM block N+1 (still L1 block L): CoreWriter action processed after block N was built; Core→EVM transfer queued until this block | 150 | 50 | 200 | yes — both the Core debit and the wallet credit have landed |
| EVM blocks N+2 … (until `_SETTLEMENT_WINDOW` elapses) | 150 | 50 | 200 | yes, but mint/burn stay locked as a conservative guard (delayed actions, sequencing edge cases) |
| After `_SETTLEMENT_WINDOW` from the request | 150 | 50 | 200 | yes |

The deposit direction differs for one reason only: a deposit moves EVM state *synchronously* with the request (the wallet is debited in the same transaction) while the Core credit lags until the EVM block is built — so deposits need the in-flight add-back for their own block. A withdrawal moves no EVM state at request time, so there is nothing to compensate. In both directions the published timing guarantees both sides have caught up by the next EVM block; the timestamp lock on top is conservative defense-in-depth, not a requirement of the transfer mechanics.

#### Reading balances during the lock

There are two read paths with different semantics:

- `EApps.getAppTokenBalances` (the path every on-chain NAV write uses, and the one `purge` uses) asserts the settlement lock in the `HYPERLIQUID` branch: it reverts with `NavLocked()` while the window is open (unless the caller is the exempt `updateUnitaryValue`).
- `ENavView.getNavDataView` (`NavView`) calls the balance reader directly with no lock assertion: it never reverts and never excludes the Hyperliquid balances. During the window it reports the raw precompile value (it also drops the in-flight add-back once the EVM block advances, exactly like `EApps` would). This is deliberate: it is the designated read path for the off-chain nav shield, which applies its own tolerance policy and must remain able to observe the pool during settlement. Callers that need a guaranteed-current NAV should wait for the window to elapse (readable from `lastActionTimestamp` in `HyperliquidData`) rather than treat a `NavLocked` revert from `EApps` as an error condition.

### Cross-chain donate exemption (issue #959)

**Severity**: ~~MEDIUM~~ **FIXED** — the lock must never block a destination-chain `donate` fill.

`ECrosschain.donate` calls `updateUnitaryValue()` in both phases, so when the settlement lock was previously enforced inside the on-chain balance reader, a fill landing while the window was open reverted with `NavLocked()`. Because the Across `MulticallHandler` executes the fill atomically, the entire fill failed: a dust Hyperliquid action could DOS an arbitrarily large cross-chain transfer, recoverable only via the escrow refund path after deposit expiry.

Fix: the lock is asserted in the `HYPERLIQUID` branch of `EApps` (fail-closed — every NAV-writing method is locked by default) with `updateUnitaryValue` as the single explicit exemption (transient flag, see above). Cross-chain `donate` is NAV-neutral in Transfer mode and routes both phases through `updateUnitaryValue`, so fills are never blocked.

Note: an interleaved Hyperliquid deposit between donation init and finalize still reverts — with `NavManipulationDetected` from the strict NAV-integrity check rather than `NavLocked`. The donation invariant only accounts for the token-balance delta, so a pending Core credit between phases is conservatively flagged as a NAV change.

#### Robustness of the cross-chain fill

A legitimate destination-chain fill cannot revert from the settlement lock, the in-flight add-back, or an interleaved action, for three independent reasons:

1. **The production fill is atomic.** The Across `MulticallHandler` executes the whole fill — `donate(1)` → token transfer → `donate(amount)` — in a single transaction. No external transaction can interleave between phases, and the transient donation lock persists across the phases of that one transaction.
2. **A non-atomic interleave reverts earlier.** The donation lock is transient storage: it is cleared when the transaction ends. A `donate` finalize attempted in a later transaction, after any number of interleaved external transactions, reverts with `DonationLock(false)` because the init phase is no longer detectable. `NavManipulationDetected` is reachable only by constructing init and finalize as separate calls inside one transaction.
3. **No third party can insert a Hyperliquid write into the atomic fill.** Adapter write access is gated by `msg.sender == pool().owner` in `MixinFallback`: a call from the `MulticallHandler` (or any non-owner address) is routed via `staticcall`, so any state write reverts. The only party able to construct an interleaved atomic batch is the pool owner — via an owner-crafted `AMulticall` — and such a batch can only grief the owner's own fill, which is not a DOS vector against other parties. `NavManipulationDetected` on this path is defense-in-depth against instruction substitution, exercisable in tests only.

Timing interacts with none of this: both phases route through the exempt `updateUnitaryValue`, so a fill succeeds whether it lands in the same EVM block as a Hyperliquid action (the in-flight amount applies identically at both phases), in the following blocks inside the window (the Core precompile has caught up per the interaction-timings sequence), or after the window. A front-running operator deposit does not break the fill either: the deposit is NAV-neutral and is reflected identically at both donation phases. Delayed Core actions (limit-order fills, vault transfers) execute between EVM blocks and therefore cannot land between the atomic phases.

The residual operator-griefing surface accepted by design is limited to locking `mint`/`burn`/`purge` via repeated dust actions, and is covered by the known-limitation paragraph above. Destination-chain `donate` fills are fully immune to it; bug reports claiming a nav-lock DOS of cross-chain `donate` should be dispositioned as not applicable.

Regression coverage: `testFork_DonateSucceedsDuringSettlementWindow` and `testFork_DonateFinalizeRevertsOnInterleavedHyperliquidAction` in `test/extensions/AHyperliquidFork.t.sol`.

### External transfers and the lock

The settlement lock is armed only by calls to the Hyperliquid adapter (`AHyperliquid.deposit` and `AHyperliquid.sendRawAction` with `SPOT_SEND`). An external party cannot arm the lock by sending tokens directly to the pool, because that action never writes `lastActionTimestamp`. Therefore an external transfer cannot freeze mint/burn or trigger `NavLocked()`.

Likewise, the same-block in-flight amount is only adjusted by the adapter. An external USDC transfer into the pool is simply reflected in the pool wallet balance on the next NAV update (after the lock expires, if any). It does not interfere with Hyperliquid's internal accounting.

## Limit orders and same-block fills

Limit orders are forwarded as-is to CoreWriter and do not call `recordAction`, so they do not arm the settlement lock — deliberately. Orders do not move funds between HyperEVM and HyperCore, so there is no same-block in-flight imbalance for a lock to fix; their Core value effects are *delayed actions* that can land after any fixed time window, so a timestamp lock cannot guarantee freshness for them anyway; and arming the lock on every order/cancel would freeze `mint`/`burn`/`donate` for `_SETTLEMENT_WINDOW` after each of a trading pool's routine operations — an operator self-DOS with no freshness benefit.

Marketable limit orders that fill immediately can therefore change the Core account value before the precompile view reflects the fill: no on-chain guard covers this path, so NAV-sensitive operations should wait for HyperCore settlement after a fill. This path is operator-gated (only the pool operator can place orders, and only the operator can time a NAV write against a fill), it falls under the same accepted operator-responsibility limitation as big-block operation above, and it is **not a valid bug-bounty finding**. The off-chain nav shield is the monitoring mitigation.

## Bridge gas reserve

`SPOT_SEND` keeps a small USDC buffer in the Core spot account to pay the spot->EVM bridge fee.

## EOracle on HyperEVM

HyperEVM does not have a deployed Rigoblock BackGeoOracle / Uniswap V4 hook, so `EOracle` is deployed with a zero/dummy oracle address. `EOracle.hasPriceFeed` is the single source of truth for whether a token can be priced on a chain:

- On HyperEVM, `EOracle.hasPriceFeed(token)` returns `true` **only** for `USDC` (`HLConstants.usdc()`).
- It returns `false` for native currency (`address(0)`), wrapped native (`WHYPE`), and every other token.

This behavior is intentional and defines the Hyperliquid integration as **USDC-only**. It is not a bug, and it must not be "fixed" to return `true` for additional tokens.

A related invariant holds in `EOracle.convertTokenAmount` / `convertBatchTokenAmounts`: **identity conversions (amount == 0 or token == targetToken) never consult the oracle**, and the target TWAP is computed lazily, only when a batch element actually requires conversion. This is what allows USDC-denominated flows (e.g. cross-chain `donate` finalization, where USDC is converted to the USDC base token) to work on HyperEVM despite the absent oracle. Non-identity conversions still revert, as they should: there is genuinely no feed.

### Consequences of the USDC-only feed

Any operation that triggers a NAV update — including `mint`, `burn`, cross-chain transfers (`donate`/ECrosschain), and owner NAV reads — will revert if the pool needs a price feed for a non-USDC token. Specifically:

- The pool's **base token** must be USDC. `MixinPoolValue._updateNav` asserts `IEOracle.hasPriceFeed(baseToken)` before computing NAV; on HyperEVM this assertion is equivalent to `baseToken == USDC`.
- The pool can only own/track **USDC** as an active asset. `EnumerableSet.addUnique` and the application balance logic use `hasPriceFeed` to decide which tokens can enter the active set; non-USDC tokens are rejected.
- `AHyperliquid` only accepts **USDC** deposits into HyperCore (`destinationDex = 0` and `token == HLConstants.USDC_TOKEN_INDEX`).

In short: on HyperEVM, **USDC is the only valid base token, ownable token, and HyperCore deposit token**. Pools or operations that require pricing for any other token will revert by design.

## Deployment and verification on HyperEVM

HyperEVM uses a dual-block architecture: small blocks every ~1 second with a 3M gas limit, and big blocks every 60 seconds with a 30M gas limit. There is no Hardhat gas-price flag that forces a transaction into a big block; the deployer address itself must have the HyperCore user flag `usingBigBlocks: true` so that the sequencer selects the big-block mempool for its transactions.

The deploy pipeline now attempts to enable this flag automatically. When running on HyperEVM, `src/deploy/deploy_extensions.ts` calls `enableHyperEVMBigBlocks()` (`src/utils/hyperliquid.ts`), which signs and submits the `evmUserModify` action to the Hyperliquid exchange API. If the action succeeds, the deployer is configured for big blocks and standard `yarn deploy --network hyperliquid` / `yarn hardhat verify --network hyperliquid` work without any manual step.

### Prerequisite: deployer must be a HyperCore user

The `evmUserModify` action can only be submitted by an existing HyperCore user. For an EOA, this means the address must have received a Core asset (e.g. USDC) on HyperCore at least once. If the automatic call fails with a "user does not exist" error, fund the deployer address on HyperCore before retrying. You can also run the helper task manually:

```bash
yarn hardhat hyperliquid:enable-big-blocks --network hyperliquid
# testnet:
yarn hardhat hyperliquid:enable-big-blocks --network hyperliquid --testnet
```

For details on the dual-block mechanism, see the [HyperEVM dual-block architecture docs](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/dual-block-architecture).

## References

- [`AHyperliquid.sol`](../../contracts/protocol/extensions/adapters/AHyperliquid.sol)
- [`HyperliquidLib.sol`](../../contracts/protocol/libraries/HyperliquidLib.sol)
- [`MixinPoolValue.sol`](../../contracts/protocol/core/state/MixinPoolValue.sol)
- [HyperEVM dual-block architecture](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/dual-block-architecture)
- [HyperEVM interaction timings](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interaction-timings)
- [Hyperliquid CoreWriter docs](https://docs.chainstack.com/docs/hyperliquid-corewriter)
