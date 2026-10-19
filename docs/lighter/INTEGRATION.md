# Lighter Integration

Rigoblock's Lighter integration lets a smart pool hold LighterCore perp positions and values them
on-chain from LighterCore state, mirroring the [Hyperliquid integration](docs/hyperliquid/INTEGRATION.md)
pattern. This document is written for peer review — including by the Lighter team — and records every
assumption we could not verify against a running LighterEVM, since LighterEVM is a young
implementation and its docs/repo state is explicitly "not production-ready".

**Status (2026-10-19): devnet (chain 19 529).** The integration follows the authoritative
"Reading Core from EVM" docs (envelope, payload layouts, `found` semantics). Selector names and
input lengths were verified live against the first devnet build by probing the precompile; that
build was subsequently wiped (all predeploy state disappeared while the chain kept producing
blocks — a documented devnet-reset hazard), so return layouts rest on the docs. All 60 Lighter
tests pass: 49 offline unit/lib tests and 11 fork tests at `LIGHTER_BLOCK = 842_000` with
precompile/predeploy returns mocked via `vm.mockCall` (Foundry cannot execute the client-side
precompile when forking, and the devnet's predeploy code can vanish at any time).

## Scope

- **Perps only.** Spot markets (IDs 2048–4095) are rejected by the adapter.
- **USDC collateral only**, USDC as the pool's base token. No oracle is deployed on LighterEVM, so
  `EOracle` has a HyperEVM-style carve-out: only USDC "has a price feed". Pools cannot hold other
  tokens, which removes oracle risk entirely.
- **No API keys in phase 1.** The adapter deliberately does not expose `changePubKey`, so every
  order must go through the EVM entrypoint — where every tradeable market is pre-tracked for NAV.
  See [API_KEYS.md](API_KEYS.md) for the full analysis (including the peer-project request).
- Out of scope: L1⇄EVM bridging via adapters, ETH collateral, outcome markets, Lagoon-style
  off-chain NAV.

## Chain facts (devnet state, from apidocs.lighter.xyz 2026-10-19)

| Property   | Value                                                                                     |
| ---------- | ----------------------------------------------------------------------------------------- |
| Chain ID   | `19_529` (devnet)                                                                         |
| Block time | 1 s                                                                                       |
| Gas limit  | 17 M hard block limit; 4.25 M is the gas _auction target_ (pricing), not an execution cap |

The 17 M hard limit is what bounds our NAV loop; the 4.25 M figure governs fee
auction pricing and would only matter if LighterEVM enforced it as a per-tx cap,
which it does not.
| Deterministic deploys | SafeSingletonFactory preinstalled at the canonical `0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7` |
| Public RPC / explorer | access-gated devnet RPC only (`LIGHTER_RPC_URL`); no public endpoint yet |

## Architecture

```
User (pool owner)
   │ delegatecall
   ▼
Pool proxy ──► MixinFallback ──► ALighter (adapter, Authority-routed, owner-write-gated)
                                    │                         │
              ┌─────────────────────┴──────┐      ┌───────────┴────────────┐
              ▼                            ▼      ▼                        ▼
  EvmInteropManager 0x6600…0001   EvmToCoreEntrypoint 0x6600…0009   READ_CORE 0x6600…0000
  (deposits / withdrawals)        (orders / cancels, async reqId)   (staticcall NAV reads)
              │                            │                          │ (pinned to parent
              ▼                            ▼                          ▼  Core block)
        LighterCore ◄──────────────────────────────────────────────────┘
```

- The adapter runs in pool context via `delegatecall`; all state lives in the pool proxy
  (Rigoblock rule: adapters hold no storage).
- Write access is enforced by `MixinFallback` (`shouldDelegatecall = msg.sender == pool.owner`),
  not by modifiers inside the adapter. Non-owners are `staticcall`ed, so state writes revert.
- `ALighter`'s constructor locks it to `block.chainid == 19_529` (deploying it anywhere else
  reverts with `NotLighterEVM`).
- The deposit activates the `LIGHTER_PERPS` application bit (append-only `Applications` enum),
  which makes the pool's NAV include Lighter balances via `EApps`/`NavView`.

## Predeploys and READ_CORE

All addresses are in the stable `0x6600…` range per the docs; the devnet USDC address is **not**
stable (see "Devnet vs stable addresses").

| Address                                      | Role                                                            |
| -------------------------------------------- | --------------------------------------------------------------- |
| `0x6600…0000`                                | `READ_CORE` precompile: staticcall views into LighterCore state |
| `0x6600…0001`                                | `EvmInteropManager`: user-facing token ops EVM⇄Core             |
| `0x6600…0009`                                | `EvmToCoreEntrypoint`: user-facing account/order writes         |
| `0x6600…000c`                                | Canonical WETH9 predeploy                                       |
| `0xf2A5728d366c6d0f764Af612cD47F3608E2B4d5B` | Devnet USDC, `assetIndex = 3`                                   |

READ_CORE calls are `abi.encodePacked(uint16 selector, args)`, ~20 k gas each, and **reads are
pinned to the parent Core block snapshot — a Core write is never visible in the same EVM block that
made it**. READ_CORE is a _client-side_ precompile: it has no on-chain code (`eth_getCode` returns
empty) and the node intercepts calls to it, which is why Foundry forks cannot execute it and the
fork tests mock its return data.

**Return convention (from the authoritative "Reading Core from EVM" docs):** every read except
tx status (`0x0000`) returns `abi.encode(bool found, bytes data)`, with the object payload inside
`data`. A read of a nonexistent account/asset/market **still succeeds** with `found = false` and
empty `data`; a read only fails (consuming all forwarded gas) on an unsupported selector, malformed
input, or < 20 k gas forwarded. `LighterLib` mirrors this: `_readCoreData` unwraps the envelope and
reverts `LighterReadFailed` when `found` is false, and `coreAccountExists` treats both `found ==
false` (docs behavior) and a failed call (observed on the first devnet build) as "no account".
`LighterTypes` holds the payload structs exactly as the docs specify them.

| Selector | Query             | Input encoding                   | Payload in `data` (when `found`)                                                                                                                                                                                             |
| -------- | ----------------- | -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `0x0000` | tx status         | `uint64 reqId`                   | **No envelope** — `abi.encode(uint8 status, bytes data)` directly: `0` pending, `1` success, `2` failed; transfer responses carry the accepted amount in `data` (output live-verified on the 2026-10-19 devnet)              |
| `0x0001` | account info      | `address, bool`                  | `(uint8 accountType, uint48 accountIndex, uint48 masterAccountIndex, address l1Address, address evmAddress, int128 collateralBaseAmount)` — shared USDC margin, 6-dec; **excludes isolated margin**                          |
| `0x0002` | decimals          | `uint32 assetIndex`              | `uint8` decimals (USDC → 6)                                                                                                                                                                                                  |
| `0x0003` | L1 token          | `uint32 assetIndex`              | L1 token address                                                                                                                                                                                                             |
| `0x0004` | EVM token         | `uint32 assetIndex`              | EVM token address (USDC idx 3 → `0xf2A5…4d5B`)                                                                                                                                                                               |
| `0x0005` | market info       | `uint16 marketId`                | `(uint8 marketType, uint32 baseAssetId, uint32 quoteAssetId, uint32 takerFee, uint32 makerFee, uint64 minBaseAmount, uint64 minQuoteAmount, uint32 liquidationFee, uint64 indexPrice, uint64 markPrice)`                     |
| `0x0006` | spot balance      | —                                | (unused; perps only)                                                                                                                                                                                                         |
| `0x0007` | position          | `address, bool, uint16 marketId` | `(int64 lastFundingRatePrefixSum, int64 position, uint56 entryQuote, uint16 initialMarginFraction, uint64 totalOrderCount, uint64 totalPositionTiedOrderCount, uint8 marginMode /*0 cross, 1 iso*/, int128 allocatedMargin)` |
| `0x0008` | L1 account index  | `address l1Address`              | (unused)                                                                                                                                                                                                                     |
| `0x0009` | EVM account index | `address accountAddress`         | `uint48` Core account index for an EVM address                                                                                                                                                                               |

Selector names and input lengths were verified live on the 2026-10-19 devnet build by probing with
malformed calldata (the node responds with `PrecompileErrorWithContext("<query name>")`); the
payload layouts above are taken from the docs, which the code now follows exactly. Selectors ≥
`0x000a` revert "Unknown query type". Selectors the adapter itself uses: `0x0000` (tx status,
in-flight accounting), `0x0001`, `0x0005`, `0x0007`, `0x0009`.

> **`0x0009` note for the Lighter team.** The docs specify the input as
> `abi.encodePacked(uint16(0x0009), accountAddress)` — 22 bytes — and `LighterLib.readEvmAccountIndex`
> sends exactly that. The first devnet build rejected that shape ("Invalid input length for account
> index"), and that build has since been wiped (all predeploy state disappeared while the chain
> kept producing blocks), so the mismatch could not be re-verified. If the current precompile
> still rejects the documented encoding, one of the two sides needs fixing before mainnet; a wrong
> encoding here bricks `sendToEvm` (it reverts `AccountNotActivated` for pools that do hold a Core
> account).

## Deposit flow (no spot step, no account activation)

Unlike Hyperliquid, there is **no account-activation prerequisite** and **no spot-account hop**:

1. Owner calls `pool.sendToCore(assetIndex=3, to=pool, isL1Account=false, amount, RouteType.Perps)`.
2. The adapter enforces: USDC only, `to == pool`, perps route only (`RouteType.Perps` —
   spot-route deposits are rejected; `marketType`/route is always 0 in our flows), `amount > 0`,
   `msg.value == 0`.
3. Per-call ERC20 approve of the exact amount to the interop manager, then `sendToCore`, then
   allowance reset to 1 (Pattern 2 — the manager uses plain `transferFrom`, not Permit2).
4. First deposit auto-creates the pool's Core master account (+146 k gas), owned by the pool's EVM
   address. Subsequent deposits reuse it. **No account-activation step exists** (unlike Hyperliquid).
5. `recordAction(+amount, reqId)` records the in-flight amount and the Core `reqId` for
   transaction-status-driven in-flight accounting (below).
6. The `LIGHTER_PERPS` application bit is activated (append-only `Applications` enum), which
   makes the pool's NAV include Lighter balances via `EApps`/`NavView`.

**Partial acceptance risk (Lighter-documented caveat).** Deposits may be _partially accepted_ on
Core, with the remainder returned by a **separate exogenous refund transaction** that is **not
retried on failure** — per the Lighter docs, a reverted refund/delivery means "the unaccepted
amount is neither credited on Core nor delivered on EVM, so the funds are lost." We document
this prominently; there is nothing the adapter can do to force a retry. Mitigation is
operational: deposit round amounts, monitor `reqId` status (READ_CORE `0x0000`), and reconcile
refunds. **Open question 4 for the Lighter team: refund retry policy.**

## Withdrawal flow

1. Owner calls `pool.sendToEvm(accountIndex, assetIndex=3, evmRecipient=pool, RouteType.Perps, baseAmount)`.
2. The adapter enforces USDC, perps route (`RouteType.Perps` only — spot-route withdrawals are
   rejected), `evmRecipient == pool` (the pool is forced as recipient, making the arrival
   NAV-neutral), `baseAmount > 0`.
3. The Core account index is resolved from READ_CORE `0x0009`; if the pool has no Core account yet,
   it reverts `AccountNotActivated`. Per the docs, reads of a nonexistent account still succeed
   with `found = false` (the first devnet build failed the call outright instead, which
   `coreAccountExists` also tolerates). Core-side write failures are asynchronous — the EVM
   transaction succeeds and the failure only surfaces as `status == 2` on the `reqId` (e.g. error
   `6506` "no pre-existing Core master account"). The adapter therefore pre-checks `0x0009`/`0x0001`
   and reverts early, and treats a failed `reqId` as "no adjustment" rather than a revert.
4. `recordAction(−baseAmount, reqId)` — USDC's Core tick size is 1, so base units are already
   6-dec USDC.
5. Delivery to the pool is **async** (Core→EVM exogenous transaction, EIP-2718 type `0x7E` from the
   Core system address `0x7fff…ffff`, 350 k gas fixed limit for ERC-20 delivery). The same
   non-retried-delivery caveat as refunds applies: if delivery reverts it is never retried and the
   Core debit is not restored. The pool is a plain token recipient (no hooks, plain `receive()`),
   so delivery cannot run out of gas.

## Trading flow and tracked markets

`createOrder(accountIndex, marketIndex, clientOrderIndex, orderType, timeInForce, orderExpiry,
amount, price, isAsk, reduceOnly, triggerPrice)` is forwarded verbatim to the Core entrypoint
(adapter interface mirrors the predeploy signature per Rigoblock rule 21; the pool's own account
index is substituted for the caller-supplied one).

Two hard guards run before forwarding:

- `marketIndex < FIRST_SPOT_MARKET_ID (2048)` — perps only (perp IDs are 0–254).
- `LighterLib.isTrackedMarket(marketIndex)` — reverts `MarketNotTracked` otherwise.

**Every market the pool can trade must be tracked first** via
`trackMarket(marketId, sizeDecimals, priceDecimals)` (pool-owner gated by `MixinFallback`):

- validates on Core that the market is a perp (`marketType == 0`). **Perps carry
  `quoteAssetId == 0`** (verified live: perp market 0 returns `quoteAssetId = 0` while spot
  market 2048 returns `quoteAssetId = 3` for USDC) — so `marketType == 0` is itself the
  USDC-settlement guarantee by protocol design (Core position `entryQuote`/`allocatedMargin`
  and account `collateralBaseAmount` are all USDC-denominated), and no quote-asset check
  applies;
- records the market's `size_decimals`/`price_decimals` (from LighterCore's `orderBookDetails`
  API; not available on-chain — **Open question 6**);
- enforces the cap of `MAX_TRACKED_MARKETS = 32`.

`untrackMarket` removes a market but only when the pool's position size on it is zero
(`PositionNotClosed` otherwise), and uses swap-remove on the tracked array.

This design makes **untracked-position NAV risk structurally impossible for all EVM-initiated
flows**: the NAV loop only iterates tracked markets, and `createOrder` cannot touch an untracked
market. The residual risk vector is API-key trading (off-chain), which is why phase 1 excludes
`changePubKey` — see [API_KEYS.md](API_KEYS.md).

`cancelOrder` / `cancelAllOrders` are forwarded unchanged (no NAV tracking impact).

## NAV computation

LighterEVM has **no aggregated perps account-value read** (the Hyperliquid
`accountMarginSummary.accountValue` equivalent does not exist). NAV is therefore _computed_:

```
NAV_usdc = collateralBaseAmount                                  (READ_CORE 0x0001, 6-dec)
         + Σ_markets  positionValue(market)                      (only tracked, size ≠ 0)
         [+ in-flight adjustment, tx-status driven, ≤ 16 s window]

positionValue = markValue − signedEntryQuote
              + (marginMode == 1 ? allocatedMargin / 1e6 : 0)

markValue          = position × markPrice × 1e6 / 10^(sizeDecimals + priceDecimals)   (signed)
signedEntryQuote   = position > 0 ? entryQuote : −entryQuote
```

### Decimal scales (three different USDC scales coexist — this was a real bug source)

| Field                           | Scale         | Notes                                             |
| ------------------------------- | ------------- | ------------------------------------------------- |
| `collateralBaseAmount` (0x0001) | 1e6 per USDC  | shared cross/isolated collateral, used as-is      |
| `entryQuote` (0x0007)           | 1e6 per USDC  | **entry NOTIONAL value, not a price** — see below |
| `allocatedMargin` (0x0007)      | 1e12 per USDC | isolated margin only; divided by 1e6              |

The "12 decimals" figure in the Lighter docs refers to `allocatedMargin` (and Core's
internal margin accounting), _not_ to the collateral balance or entry values. An early
implementation treated `entryQuote` as an entry _price_ and mixed scales; the fork test
`testFork_NavWithTrackedPosition` (a +2 USDC PnL valued at 2 wei without the fixed 1e6
factor) and review of the Lighter docs caught it.

### Why mark-to-market minus entry notional

Core semantics (docs, "Reading Core from EVM" / position query): `position` is the signed
size on `createOrder`'s amount scale; `markPrice` is a _price_ (quote whole units ×
10^priceDecimals, e.g. BTC at 50 000.0 with `price_decimals = 4` is `500000000`);
`entryQuote` is the unsigned entry **notional** in Core USDC base units (1e6 per USDC) —
i.e. Core has already multiplied entry price × size for us. Converting the mark value to
6-dec USDC needs the fixed USDC 1e6 factor (constant because perps are USDC-settled by
design); the entry value needs no conversion at all. Longs subtract `+entryQuote`, shorts
`-entryQuote`.

- Isolated-margin positions add back `allocatedMargin` (12-dec USDC) because isolated margin is
  not part of the shared collateral balance. Cross-margin positions need no adjustment. Both
  margin modes are handled and unit-tested (long/short × cross/isolated).
- Unrealized PnL is mark-to-market: every NAV read revalues open positions at Core's current
  mark price against the frozen entry notional, so a position moving in price changes NAV on
  the next read. Unit tests cover PnL in both directions; the fork NAV test values a live
  tracked position against the devnet mark price.
- The in-flight amount is applied only while the transfer's `reqId` is in the expected
  pending/success state and within the 16 s window (see below).
- If the total is exactly zero: the pool reports a dust value of 1 while it has a Core account
  or a recent action (so the app stays valued and the branch stays active), and an empty
  balance list otherwise.

**Trust assumption (vs Hyperliquid).** Position value uses **Core's own mark price**, which the
Core operator influences by design (mark pricing, backrunning, liquidations). This is a stronger
trust assumption than Hyperliquid's authoritative `accountValue`, and is the main reason the
32-market cap exists: NAV cost scales linearly with tracked markets (see below), and every extra
market is another mark-price surface. Documented for the audit; accepted for phase 1 because
LighterCore is itself the counterparty oracle for these positions.

Funding payments are captured implicitly: `lastFundingRatePrefixSum` is in the position struct but
Rigoblock's NAV formula deliberately uses only `entryQuote` vs `markPrice` — the mark price
reflects the funding-adjusted exchange state at read time. **Open question: confirm funding is
settled into/through the mark or collateral balance on LighterCore.**

### NAV routing: why the computation lives in the adapter

`LighterLib` (~2.3 kB) cannot compile into `EApps`/`ENavView`: both extensions are within ~120
bytes of the 24 576-byte contract-size limit, and inlining the lib pushed `ENavView` over it. The
computation therefore runs on `ALighter` itself, reached through a staticcall-safe route:

1. The `LIGHTER_PERPS` branch of `EApps.getAppTokenBalances` / `NavView.getAppTokenBalances` calls
   `IALighter(pool).getLighterBalances(pool)`.
2. The pool's `MixinFallback` routes the unknown selector through
   `Authority.getApplicationAdapter` to `ALighter`. Crucially, non-owner callers (including the
   pool itself when the original caller is not the owner) are **staticcall**ed, so the whole route
   works for any NAV reader. `getLighterBalances` carries **no `onlyDelegateCall` guard** and makes
   no state writes, so it is safe under both staticcall and delegatecall (the pool owner gets
   delegatecall via the normal fallback rule; the function is view-pure either way).
3. Because the adapter runs under staticcall and cannot read pool storage, `EApps` exposes the
   Lighter slot through a new extension view `getLighterTrackedMarkets()` (returns
   `LighterViewData{ marketIds, sizeDecimals, priceDecimals, lastActionBlock,
lastActionTimestamp, lastReqId, inFlightAmount }`).
   `ExtensionsMap` routes it to `EApps` with `shouldDelegatecall = true`.
4. `ALighter.getLighterBalances` passes the pool address and the view data to
   `LighterLib.getLighterBalances(account, viewData)`, which performs the READ_CORE reads.

Security properties of this route: write-mode access is unchanged (deposits/orders go through the
owner-gated delegatecall path); the settlement lock is asserted in the `EApps` branch _before_ the
external call, fail-closed; and the adapter only reads storage through the typed `IEApps` view, so a
malicious adapter registered via governance could lie about balances only within the same trust
model as any adapter (governance is trusted).

**Accepted caveat (runaway selector).** Unlike the Hyperliquid branches, which inline their NAV
computation in `EApps`/`ENavView`, the Lighter branch routes through Authority — so if governance
ever _removed_ the `getLighterBalances` selector mapping, NAV evaluation for pools with the
LIGHTER bit would revert and mint/burn would brick until the mapping was restored. Governance is
trusted in this model (it can already swap any adapter), and the alternative — inlining
`LighterLib` into `EApps`/`ENavView` — breaches the 24 576-byte contract-size limit (both
extensions are within ~120 bytes of it). The recommended structural fix is the per-chain
`EApps` split discussed below, which removes the size pressure entirely.

This mirrors how Hyperliquid keeps NAV code in the extensions only because `HyperliquidLib` fits;
if a future LighterLib shrink or an aggregated READ_CORE selector removes the size pressure, the
computation can move back into `EApps`/`ENavView` without changing semantics.

## Follow-up: per-chain `EApps` split and `ENavView` removal (postponed)

`EApps` today carries GMX, Uniswap V4, Hyperliquid, and Lighter NAV branches in one contract on
every chain, and `ENavView` near-duplicates it for the client-side view path. Review surfaced
two structural improvements, both **deliberately postponed** past this integration:

1. **Per-chain extensions**: a base NAV contract (tokens + generic positions) with
   `EAppsArbitrum` (adds GMX), `EAppsHyperEvm` (Hyperliquid branches), `EAppsLighterEvm`
   (Lighter branch). Benefits: each chain's extension is far smaller; a GMX-only fix stops
   forcing a version bump and redeploy on every chain; Lighter/Hyperliquid code leaves the
   generic `EApps`. Cost: the same protocol `VERSION` would then have different extension
   implementations per chain, and any extension change still forces an implementation
   redeploy on the affected chain.
2. **Removing `ENavView`**: it exists for DefiLlama (which now wants to reconstruct NAV
   manually) and a never-implemented SP1/zk-NAV path; it is a massive contract at the size
   limit and has historically diverged from `EApps` in edge cases. A transaction simulation
   can run against the write path instead. Removing it would free the size headroom that
   currently forces the Authority-routed NAV design above.

Together they would let NAV computation live in the extension again (no Authority dependency)
and shrink every deployment. Tracked as future work; not required for the Lighter launch.

## L1⇄Core and L1⇄EVM: deliberately out of scope

We do **not** support direct Ethereum-mainnet⇄LighterCore transfers. Lighter's
`L1InteropManager.sendToCore` (L1→Core) and Core-signed `txType 13/132` withdrawals (Core→L1)
exist, but supporting them would mean NAV-managing balances that skip the EVM entirely. Like
the Hyperliquid integration, the only supported funding path is **L1 → LighterEVM → Core**
(and back), where every hop is visible to the pool's own EVM address. L1⇄EVM bridging itself
uses Lighter's default gateways (`L1EscrowGateway`/`EvmMintGateway` and friends) directly, not
through Rigoblock adapters.

**AIntents (Across) on LighterEVM — required before mainnet.** The Across source adapter is
not wired for 19529 in this phase (the devnet has no Across deployment, and bridging is
exogenous-type messaging in Lighter's model anyway). Before any LighterEVM mainnet launch we
must either wire `AIntents` for the chain or explicitly document that cross-chain deposits
into Lighter pools are unsupported at launch. Cross-chain _deposits into_ a Lighter pool would
land in the `donate`/`depositV3` path, whose NAV evaluation runs our own tx bounded by the 17 M
block limit (see Gas analysis) — no additional constraint beyond the tracked-market cap.

## RPC / environment naming

The env variable stays **`LIGHTER_RPC_URL`** (foundry keeps its own `lighter` RPC alias in
`foundry.toml`; the fork fixture forks `"lighter"`). Hardhat's network for the devnet is
`lighterevm-devnet` (chainId 19529), named per Lighter's docs; its URL resolves from
`LIGHTER_RPC_URL` or the private `LIGHTER_DEVNET_EXPLORER_URL`. The explorer URLs for
verification are `LIGHTER_DEVNET_API_URL` / `LIGHTER_DEVNET_BROWSER_URL` — they are
access-restricted and must not be committed or published. At mainnet launch only the URL
values change — no variable or config renames. `.env.sample` documents this. The fork suite
auto-skips while `LIGHTER_RPC_URL` is unset, so CI is unaffected.

## Gas analysis and the 32-market cap

LighterEVM has a **17 M hard block gas limit** (the 4.25 M figure is the gas-auction _target_
used for pricing, not an execution cap). NAV reads happen inside `updateUnitaryValue`, which is
on the mint/burn path — and also inside cross-chain flows (`donate` on an Across destination
fill, `depositV3` accounting), so the whole tracked-market loop must fit comfortably in a
single transaction:

| Component                                                        | Approx. gas                                                                            |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| READ_CORE staticcall                                             | ~20 k **per read** (flat, vs ~2.1 k for a cold SLOAD — precompile reads are expensive) |
| Per-market NAV (1 × `0x0007` + 1 × `0x0005`)                     | ~40–50 k                                                                               |
| Account read (`0x0001`) + tx-status read (`0x0000`) + slot reads | ~60 k                                                                                  |
| **32 tracked markets, worst case all non-zero**                  | **~1.5–1.8 M**                                                                         |

Well inside the 17 M hard limit (and inside the 4.25 M auction target too) even in the worst
case. A multicall that triggers several NAV evaluations pays the full ~20 k per precompile read
each time — there is no caching between calls in the same transaction. The cap mirrors GMX's
`_MAX_GMX_POSITIONS` and is a gas heuristic only — unlike GMX, there is no "blind spot" by
construction, because the adapter cannot open positions in untracked markets and zero-size
positions are skipped (unfilled orders don't inflate NAV cost).

**The 50 k / 350 k / 380 k gas limits in the Lighter docs** (ETH delivery, ERC-20
delivery/refund, L1-account refund) are fixed limits on the _exogenous_ transactions sent by
the Core system address — they bound Core's own delivery/refund txs, not ours. Our pool is a
plain token recipient with no receive hooks, so delivery/refund txs to the pool cannot run out
of gas. Our NAV computation runs inside our own transaction, bounded only by the 17 M block
limit.

If Lighter adds an aggregated account-equity selector to READ_CORE, the cap and the per-market
decimal bookkeeping can be dropped entirely — **Open question 2**.

## Async writes, in-flight accounting, and the settlement lock

All Core writes (deposit, withdrawal, order, cancel) return a `reqId`; completion status is
READ_CORE `0x0000` (`0` pending, `1` success, `2` failed — live-verified: a real devnet
deposit returned `abi.encode(uint8 status, bytes data)` with the accepted amount in `data`).
Two consequences, mirrored from Hyperliquid:

1. **Core state is never visible in the same EVM block** — READ_CORE reads are pinned to the
   parent Core block snapshot. In-flight accounting must therefore be _driven by the
   transaction status_, not by wall-clock guesses:
   - **Deposit** (pool wallet debited immediately by the interop manager): add the amount back
     while `status == 0` (pending) — the collateral read does not show it yet. Once
     `status == 1` (or `2`), the collateral read (or the refund) is authoritative.
   - **Withdrawal**: subtract the amount only once `status == 1` (Core debit processed) — while
     pending, neither the collateral read nor the pool wallet has moved, so no adjustment is
     needed. A failed withdrawal (`status == 2`) needs none either.
   - **Orders/cancels** record `reqId == 0` and never adjust in-flight: a pending order write
     changes no Core state visible to NAV. A nonzero reqId only _replaces_ the tracked one, so
     an order after a deposit cannot clobber the pending transfer's tracking.
   - Only the latest reqId is tracked, only within the `_SETTLEMENT_WINDOW`. Batching a deposit
     and a withdrawal in one block loses per-request granularity (documented).
2. **Settlement lock.** `assertNavUnlocked()` (asserted in the `LIGHTER_PERPS` branch of
   `EApps`, fail-closed) blocks NAV-dependent state changes — mint, burn, and other locked
   flows — for `_SETTLEMENT_WINDOW = 16` seconds after any recorded Core write, same-block
   exempt. This covers refund/delivery lag beyond the in-flight window. If the tx-status read
   itself fails, NAV evaluation reverts (`LighterReadFailed` path) rather than producing an
   inaccurate value — the market was validated at track time, so a read failure means Core
   state is inconsistent.

`ENavView`/`NavView` reads are intentionally **not** locked (they are views), matching the
Hyperliquid design. The 16 s window is a starting value: **Open question 3 for the Lighter team —
what is the actual Core→EVM state-observation lag in EVM blocks?** On HyperEVM the window was tuned
against measured lag; on LighterEVM we cannot measure without sustained RPC access.

## EVM differences relevant to the integration

| Topic                                | LighterEVM behavior                                                              | Integration impact                                                                                                                                                                             |
| ------------------------------------ | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| EIP-2718 deposit txs                 | No user-facing deposit transaction type                                          | Nothing to handle in the adapter                                                                                                                                                               |
| Type `0x7E` txs                      | Exogenous txs from Core system address `0x7fff…ffff` deliver withdrawals/refunds | Pool's USDC arrives asynchronously; no code path needed                                                                                                                                        |
| Precompiles                          | `0x6600…` range incl. READ_CORE                                                  | Standard `staticcall`; no special casing                                                                                                                                                       |
| CREATE2 / DELEGATECALL / EXTCODEHASH | No documented deviations                                                         | Proxy + adapter patterns unaffected                                                                                                                                                            |
| `block.number` / timestamps          | 1 s blocks                                                                       | Settlement window uses `block.timestamp`                                                                                                                                                       |
| Account activation                   | **None required** (vs Hyperliquid's builder requirement)                         | First deposit auto-creates the Core account; a nonexistent account reads as `found = false` per the docs (the first devnet build failed the call instead — `coreAccountExists` tolerates both) |

## Storage layout

All Lighter state lives in one ERC-7201-style slot in the pool proxy
(`keccak256("pool.proxy.lighter.data") − 1`, accessor `StorageLib.lighterSlot()`), mirroring the
`HyperliquidData` pattern (adapter-app storage slots are asserted by convention, not in
`MixinStorage`):

```solidity
struct LighterData {
  uint48 lastActionBlock;
  int128 inFlightAmount;
  uint48 lastActionTimestamp;
  uint64 lastReqId;
}
struct TrackedMarket {
  uint8 sizeDecimals;
  uint8 priceDecimals;
}
struct LighterSlot {
  LighterData data;
  uint16[] trackedMarkets; // NAV iteration order
  mapping(uint16 marketId => uint256 index) marketIndex; // 1-based; 0 = untracked
  mapping(uint16 marketId => TrackedMarket) markets;
}
```

`LIGHTER_DATA_SLOT` (`keccak256("pool.proxy.lighter.data") − 1`) is deliberately a **single
umbrella slot** for all Lighter state, not a per-feature slot: today it holds perps-only data,
but the `LighterSlot` struct can be extended append-only (e.g. a spot-token array if spot is
ever added) without a new slot definition. This mirrors the `HyperliquidData` pattern
(adapter-app storage slots are asserted by convention, not in `MixinStorage`).

No extension/adapter storage (Rigoblock hard rule).

## Deployment wiring

- `VERSION` bumped to `4.5.0` (`MixinConstants.sol`); `ALighter._REQUIRED_VERSION = "4.5.0"`;
  the `pool.VERSION()` test assertion updated in the same PR.
- `extensionsMapSalt` bumped to `extensionsMapSalt20` (LighterLib compiles into `EApps`/`ENavView`/
  `EOracle` → new extension bytecode → new ExtensionsMap → new implementation).
- Chain 19 529 added to `PRODUCTION_CHAIN_IDS` in `rocketh/config.ts` with the Safe singleton
  factory (preinstalled on LighterEVM → deterministic-address parity holds).
- `src/utils/constants.ts` chainConfig: WETH9 predeploy as wrapped native; zero
  oracle/staking/uniV4/posm/router/across/wormhole entries; devnet USDC.
- `hardhat.config.ts` `lighterevm-devnet` network + fee caps (`src/utils/networkFees.ts`: 1 gwei max /
  0.01 gwei priority), `foundry.toml` `lighter = "${LIGHTER_RPC_URL}"`, `.env.sample` entries.
- `src/deploy/deploy_extensions.ts`: chain-19529 branch skips Uniswap/0x/AGovernance (not
  deployed there) and deploys `ALighter`. Selector registration in Authority is governance-driven
  (no `addMethod` in the deploy scripts): before pools can use the adapter on 19529, governance
  must register the eight selectors — `sendToCore`, `sendToEvm`, `createOrder`, `cancelOrder`,
  `cancelAllOrders`, `getLighterBalances`, `trackMarket`, `untrackMarket`. Note that
  `getLighterBalances`/`trackMarket`/`untrackMarket` must be registered for NAV to work at all,
  since the `EApps`/`ENavView` LIGHTER branches route through it.
- Explorer verification: Hardhat 3's verify plugin (v3.1.0+) has native Blockscout support and
  does **not** accept Hardhat 2's `customChains` (that is `@hh2`-tag plugin syntax — see
  Blockscout's hardhat verification guide). The HH3 equivalent is a `chainDescriptors` entry in
  `hardhat.config.ts`, declared for chainId 19529 from the private env URLs
  (`LIGHTER_DEVNET_API_URL` / `LIGHTER_DEVNET_BROWSER_URL`; no explorer URL is committed to the
  repo). Verify with the provider-scoped subcommand, which leaves the Etherscan/Sourcify config
  untouched:
  `npx hardhat verify blockscout --network lighterevm-devnet <address> [constructorArgs...]`.
  `scripts/verify-lighter-devnet.sh` batch-verifies every artifact in a deployments dir
  (`deployments/lighter` by default), decoding constructor args from each `argsData`.
  `SOLIDITY_SETTINGS` is unset for every call because the value committed in `.env` is a JS
  literal, not JSON, and crashes hardhat's config loader.
- **Verification status (2026-10-19): blocked explorer-side.** Both explorer APIs accept
  verification jobs but never process them: the Etherscan-emulation
  `?action=verifysourcecode` returns a guid and then `checkverifystatus` →
  `Fail - Unable to verify`, and the native Blockscout v2 endpoint
  `POST /api/v2/smart-contracts/{address}/verification/via/standard-input` (multipart,
  `compiler_version` / plain `contract_name` / `autodetect_constructor_args` / `files[0]`)
  returns `{"message":"Smart-contract verification started"}` after which
  `GET /api/v2/addresses/{address}` keeps reporting `is_verified: false` indefinitely.
  Reproduced with the exact UI parameter semantics and with a trivial solc 0.8.24
  single-file probe, so the failure is not our input. The v2 API is the right interface
  once axiom fixes the backend; curl example for one contract:
  `curl -X POST "$LIGHTER_DEVNET_BROWSER_URL/api/v2/smart-contracts/<address>/verification/via/standard-input" -F compiler_version=v0.8.37+commit.f401782d -F contract_name=<Name> -F autodetect_constructor_args=true -F "files[0]=@<Name>.json"`.
  Reported for the Lighter/axiom team: the verifier worker appears unprovisioned on the
  devnet.
  Local correctness evidence while blocked: for 12 of 15 contracts the deployment
  artifact's `deployedBytecode` is byte-identical to `build/artifacts` (metadata included).
  `Authority`, `PoolRegistry`, and `RigoblockPoolProxyFactory` (all pinned-solc-0.8.17)
  have byte-identical _executable_ code but their on-chain metadata CBOR tail is the
  pre-Hardhat-3 canonical tail, which the current build's standard-json does not reproduce.
  The exact input can be recovered from mainnet Etherscan instead — same deterministic
  address, verified there with the historical standard-json: verified locally for
  `Authority` (its Etherscan standard-json recompiles to the Lighter deployment
  byte-for-byte with the cached `solc 0.8.17+commit.8df45f5f`), pending for the other two.

## Testing

| Suite          | File                                                                                | Status                                                                                      |
| -------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Unit (offline) | `test/extensions/ALighterUnit.t.sol`, `test/libraries/LighterLib.t.sol`             | 49 tests, run in CI                                                                         |
| Fork (devnet)  | `test/extensions/ALighterFork.t.sol` + `test/fixtures/LighterDeploymentFixture.sol` | **11 tests pass** at `LIGHTER_BLOCK = 842_000`; auto-skips while `LIGHTER_RPC_URL` is unset |

The fork fixture mirrors `HyperliquidDeploymentFixture`: it uses live Authority/Registry/Factory
from `Constants` when present, else deploys local infrastructure, and registers the adapter
selectors (with the whitelister self-grant needed on live infrastructure). Foundry's EVM cannot
execute the client-side READ_CORE precompile when forking, so all precompile returns are mocked
with `vm.mockCall` (a wildcard revert in the fixture + per-test mocks), following the enveloped
`abi.encode(bool found, bytes data)` convention from the docs. The `EvmInteropManager`
(`0x6600…0001`) `sendToCore` return is likewise mocked with an exact-calldata matcher — this
asserts the adapter builds the correct calldata (a wrong encoding misses the mock and hits the
wildcard revert) while keeping the suite independent of the devnet's predeploy code, which can
disappear without notice (the first devnet build was wiped wholesale mid-integration; a later
build may serve state again at the same spec addresses).

The fork suite validates chain wiring, storage effects, flow guards, NAV valuation, the
settlement lock, and adapter calldata construction. It does **not** validate live READ_CORE
returns — that requires a stable devnet and is listed in the open questions.

**Devnet-reset hazard.** Predeploy code is chain state: when Lighter resets/redeploys the
devnet, every predeploy address has no code until Lighter redeploys it, even at pinned blocks
(block headers remain queryable, but state is gone). This is environmental, not a spec change —
the `0x6600…` addresses are spec-stable. If the fork suite fails wholesale with empty-state
errors, check `eth_getCode` on `0x6600…0001` at the pin and bump `LIGHTER_BLOCK` in
`contracts/test/ForkBlocks.sol` to a block from after Lighter's redeploy.

## Security checklist disposition

- [x] Adapter write-access gated by `MixinFallback` (no `onlyOwner` modifier in adapter code)
- [x] No storage in the adapter (all via `StorageLib.lighterSlot()`)
- [x] `onlyDelegateCall` guard + constructor chain-lock (`NotLighterEVM`)
- [x] USDC-only: asset index, quote asset, and route enforced on every entrypoint
- [x] Pool forced as deposit recipient / withdrawal recipient (no third-party egress)
- [x] Per-call approve with reset-to-1 (Pattern 2, USDT-safe via `safeApprove`)
- [x] Tracked-markets gate makes untracked positions impossible via EVM flows
- [x] Settlement lock fail-closed in `EApps`; views unguarded
- [x] Reentrancy guard (transient) on all external-facing adapter methods
- [x] Custom errors throughout
- [x] `changePubKey` not exposed (phase 1) — see [API_KEYS.md](API_KEYS.md)

## Devnet vs stable addresses

The docs state the `0x6600…` predeploy layout and chain ID are stable across devnet → public
testnet → mainnet. The **devnet USDC address (`0xf2A5…4d5B`) and its asset index (3) are
devnet-only** — like `HYPER_USDC`, it must be re-verified and updated when the next LighterEVM
network launches, and the `LighterConstants` values carry a devnet-only comment saying so.

## Open questions for the Lighter team

1. **Public RPC/explorer access** — an access-gated devnet RPC exists and is enough for our fork
   tests, but a public endpoint would let CI run them continuously.
2. **Is an aggregated perps account-equity selector planned for READ_CORE?** It would remove the
   32-market cap and the per-market decimal bookkeeping entirely.
3. **Core→EVM state lag**: how many EVM blocks (or seconds) until a Core write is reflected in
   READ_CORE? Determines `_SETTLEMENT_WINDOW`.
4. **Refund/delivery failure policy**: confirm exogenous refund/delivery txs are never retried and
   document the recovery path for stranded funds.
5. **Address stability**: will devnet USDC (asset index 3) and predeploys keep the same addresses
   on public testnet/mainnet?
6. **Per-market metadata on-chain**: can `size_decimals`/`price_decimals` be added to the READ_CORE
   market info (selector `0x0005`)? Today they come from the off-chain `orderBookDetails` API and
   must be supplied by the operator at `trackMarket` time, which is an operator-error surface.
7. **READ_CORE live confirmation**: the code now implements the documented ABI exactly (envelope
   plus payload layouts in the selector table), but the first devnet build that let us verify
   selector names live was wiped before the layouts could be cross-checked against a running
   precompile — please confirm `0x0001`/`0x0005`/`0x0007` return the documented payloads on the
   current build, and settle the `0x0009` input note in the selector table if it still rejects the
   documented 22-byte encoding. Also: the funding model (is funding settled through collateral
   or mark price?).

## References

- Lighter EVM docs: https://apidocs.lighter.xyz/docs/evm-introduction
- Lighter contracts (devnet branch, moving target): https://github.com/elliottech/lighter-contracts
- Hyperliquid integration (pattern source): [docs/hyperliquid/INTEGRATION.md](docs/hyperliquid/INTEGRATION.md)
- API keys analysis: [API_KEYS.md](API_KEYS.md)
