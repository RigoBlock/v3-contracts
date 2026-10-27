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
blocks — a documented devnet-reset hazard), so return layouts rest on the docs. All 70 Lighter
tests pass: 58 offline unit/lib tests (LighterLib 18 + ALighter unit 35 + EAppsLighter unit 5),
10 fork tests at `LIGHTER_BLOCK = 51_000`, and the live suite (format-lock + NAV exactness, the
latter skipping until the tester pool is funded on the reset devnet) with precompile/predeploy
returns mocked via `vm.mockCall` on the fork (Foundry cannot execute the client-side precompile
when forking, and the devnet's predeploy code can vanish at any time).

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

## Chain facts (devnet 1.1.0 state, from apidocs.lighter.xyz changelog 2026-10-26, verified live 2026-10-27)

| Property   | Value                                                                                     |
| ---------- | ----------------------------------------------------------------------------------------- |
| Chain ID   | `19_529` (devnet)                                                                         |
| Block time | 1 s                                                                                       |
| Gas limit  | 17 M hard block limit; 4.25 M is the gas _auction target_ (pricing), not an execution cap |

The 17 M hard limit is what bounds our NAV loop; the 4.25 M figure governs fee
auction pricing and would only matter if LighterEVM enforced it as a per-tx cap,
which it does not.
| Deterministic deploys | SafeSingletonFactory preinstalled at the canonical `0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7` |
| Public RPC / explorer | access-gated devnet RPC only (`LIGHTER_DEVNET_RPC_URL`); no public endpoint yet |

## Architecture

```
User (pool owner)                                    NAV readers (anyone)
   │ delegatecall                                        │ staticcall
   ▼                                                     ▼
Pool proxy ──► MixinFallback ──► ALighter (adapter, Authority-routed, owner-write-gated)
   │                                │                         │
   │              ┌─────────────────┴──────┐      ┌──────────┴────────────┐
   │              ▼                        ▼      ▼                       ▼
   │  EvmInteropManager 0x6600…0001   EvmToCoreEntrypoint 0x6600…0009   READ_CORE 0x6600…0000
   │  (deposits / withdrawals)        (orders / cancels, async reqId)   (staticcall state reads)
   │              │                        │                          │ (pinned to parent
   │              ▼                        ▼                          ▼  Core block)
   │        LighterCore ◄─────────────────────────────────────────────────┘
   │
   └──► MixinFallback ──► ExtensionsMap ──► EAppsLighter (extension, delegatecall)
                                              │
                                              └── READ_CORE 0x6600…0000 (NAV valuation)
```

- The adapter runs in pool context via `delegatecall`; all state lives in the pool proxy
  (Rigoblock rule: adapters hold no storage).
- Write access is enforced by `MixinFallback` (`shouldDelegatecall = msg.sender == pool.owner`),
  not by modifiers inside the adapter. Non-owners are `staticcall`ed, so state writes revert.
- `ALighter`'s constructor locks it to `block.chainid == 19_529` (deploying it anywhere else
  reverts with `NotLighterEVM`).
- The deposit activates the `LIGHTER_PERPS` application bit (append-only `Applications` enum),
  which makes the pool's NAV include Lighter balances via the `LIGHTER_PERPS` branch of
  `EAppsLighter` (the chain-19529 deployment of the `EApps` family).
- **Separation of concerns:** `ALighter` owns Core _writes_ (deposits, withdrawals, orders,
  cancels, market tracking); `EAppsLighter` owns Core _reads_ and NAV valuation. Both run in
  pool context, so both read the same pool-storage Lighter slot (`StorageLib.lighterSlot()`).
  No Authority round-trip is involved in NAV.

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

READ_CORE calls are `abi.encodePacked(uint16 selector, args)` in **true packed form** (e.g. 23
bytes for account info = 2-byte selector + 20-byte address + 1-byte bool; 32-byte-padded variants
are rejected with `"Invalid input length for <query>"`), ~20 k gas each, and **reads are pinned to
the parent Core block snapshot — a Core write is never visible in the same EVM block that made
it**. Since devnet 1.1.0, `eth_call`/`debug_traceCall`/`eth_simulateV1` answer from the selected
block's Core snapshot for roughly the latest 64 EVM blocks (older blocks fail with a "Core block
outside the read window" error; past transactions remain traceable via their recorded Core
reads) — pre-1.1.0 only `latest` worked. READ_CORE is a _client-side_ precompile: it has no
on-chain code (`eth_getCode` returns empty) and the node intercepts calls to it, which is why
Foundry forks cannot execute it and the fork tests mock its return data.

**Return convention (devnet 1.1.0; docs and devnet agree).** Every read except tx status returns
the documented `abi.encode(bool found, bytes data)` envelope: `found = false` with empty `data`
(the call still succeeding) when the queried account/asset/market does not exist; a failed
staticcall means a malformed query (unsupported selector, bad input length, <20 k gas forwarded)
and is treated as an error, never as "not found". Verified live against the 1.1.0 devnet on
2026-10-27 (fresh chain after the 1.1.0 reset):

- Successful reads return the envelope wrapping the raw `abi.encode` payload (word counts in the
  table below); the read layer (`LighterLib._readCoreData`) unwraps it and hands the inner bytes
  to the typed decoders.
- **Absence is `found = false`**, never a failure: nonexistent account (0x0001, 0x0007, 0x0009),
  nonexistent asset (0x0002-0x0004), nonexistent market (0x0005; a spot marketId on 0x0007 also
  reports `found = false`).
- **Malformed queries fail the call** (JSON-RPC `-32003 PrecompileErrorWithContext("Invalid input
length for <query>" / "Unknown query type")`) and consume all forwarded gas;
  `LighterLib._readCore` reverts `LighterReadFailed` on a failed staticcall.
- **Tx status (0x0000) never fails on an unknown reqId**: it returns `abi.encode(uint8 status = 0,
empty data)` — "pending or never issued" — and is the one read with **no envelope**. Per the
  1.1.0 changelog, successful void writes now return `abi.encode(0)` in the status data.

| Selector | Query             | Input encoding                 | Inner payload (the `data` field when `found = true`)                                                                                                                                                                                                                                                                   |
| -------- | ----------------- | ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `0x0000` | tx status         | `uint64 reqId`                 | `abi.encode(uint8 status, bytes data)` directly (no envelope; never fails on unknown reqIds): `0` pending, `1` success, `2` failed (`data = abi.encode(uint32 errorCode)`)                                                                                                                                             |
| `0x0001` | account info      | `address, bool` (packed, 23 B) | `(uint8 accountType, uint48 accountIndex, uint48 masterAccountIndex, address l1Address, address evmAddress, int128 collateralBaseAmount)` — shared USDC margin, 6-dec; **excludes isolated margin**                                                                                                                    |
| `0x0002` | decimals          | `uint32 assetIndex`            | `uint8` decimals (USDC → 6)                                                                                                                                                                                                                                                                                            |
| `0x0003` | L1 token          | `uint32 assetIndex`            | L1 token address                                                                                                                                                                                                                                                                                                       |
| `0x0004` | EVM token         | `uint32 assetIndex`            | EVM token address (USDC idx 3 → `0xf2A5…4d5B`)                                                                                                                                                                                                                                                                         |
| `0x0005` | market info       | `uint16 marketId`              | `(uint8 marketType, uint32 baseAssetId, uint32 quoteAssetId, uint32 takerFee, uint32 makerFee, uint64 minBaseAmount, uint64 minQuoteAmount, uint32 liquidationFee, uint64 indexPrice, uint64 markPrice)`                                                                                                               |
| `0x0006` | spot balance      | —                              | (unused; perps only)                                                                                                                                                                                                                                                                                                   |
| `0x0007` | position          | `address, bool, uint16` (25 B) | **devnet 1.1.0 layout:** `(int64 size, uint56 entryQuote, uint16 initialMarginFraction, uint64 totalOrderCount, uint64 totalPositionTiedOrderCount, uint8 marginMode /*0 cross, 1 iso*/, int128 allocatedMargin /*6-dec USDC since 1.1.0, was 12-dec*/)` — the leading `lastFundingRatePrefixSum` was dropped in 1.1.0 |
| `0x0008` | L1 account index  | `address l1Address`            | (unused)                                                                                                                                                                                                                                                                                                               |
| `0x0009` | EVM account index | `address` (packed, 22 B)       | `uint48` Core account index for an EVM address                                                                                                                                                                                                                                                                         |

Selector names, packed input lengths, envelope semantics and payload layouts were verified live
on the 1.1.0 devnet (2026-10-27) by probing with padded/malformed calldata (the node responds
with `PrecompileErrorWithContext("<query name>")`) and match the current docs exactly. Selectors ≥
`0x000a` fail "Unknown query type". Selectors the integration itself uses: `0x0000` (tx status,
in-flight accounting), `0x0001`, `0x0005`, `0x0007`, `0x0009`.

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
   makes the pool's NAV include Lighter balances via the `LIGHTER_PERPS` branch of `EAppsLighter`.

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
   the read fails (per the docs, reads of a nonexistent account fail outright) and the adapter
   reverts `AccountNotActivated`. Core-side write failures are asynchronous — the EVM
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

One hard guard runs before forwarding: `marketIndex < FIRST_SPOT_MARKET_ID (2048)` — perps only
(perp IDs are 0–254).

**Tracking and untracking are fully automatic — no owner-facing methods** (both `trackMarket` and
`untrackMarket` were removed as public methods on 2026-10-23; the adapter exposes only the five
Core-write methods, and `ExtensionsMap` lost the `getLighterBalances` selector):

- `createOrder` auto-tracks the market on first trade (no-op if already tracked). Validation:
  the market must be in the `LighterConstants.marketDecimals` release-time table (else
  `UnknownMarket(marketId)` — see "Market decimal scales" below), and the on-Core market-info
  read must report `marketType == 0`. **Perps carry `quoteAssetId == 0`** (verified live: perp
  market 0 returns `quoteAssetId = 0` while spot market 2048 returns `quoteAssetId = 3` for USDC)
  — so `marketType == 0` is itself the USDC-settlement guarantee by protocol design (Core
  position `entryQuote`/`allocatedMargin` and account `collateralBaseAmount` are all
  USDC-denominated), and no quote-asset check applies. The cap is `MAX_TRACKED_MARKETS = 32`
  (unreachable while the table lists four markets; future-proofing).
- **At-cap behavior:** `trackMarket` is O(1) (a `marketIndex` mapping lookup — never an array
  scan). When `createOrder` tries to track a new market while the list is full it reverts
  `MaxTrackedMarketsReached`; no sweep happens there. Stale entries are pruned by the NAV loop
  instead (below), so the owner only needs any NAV-evaluating transaction (`updateUnitaryValue`,
  mint/burn, `purgeInactiveTokensAndApps` — or even an `eth_call` read, whose prunes simply do
  not persist) to clear dead entries before trading a 33rd market.
- **Purge inside NAV (not a separate sweep):** `IEApps.getAppTokenBalances` is **not view**, so
  the NAV loop itself prunes: iterating the tracked markets backwards over the live storage
  array, any market with **no open position and no open orders** (`size == 0 &&
totalOrderCount == 0 && totalPositionTiedOrderCount == 0` in the 0x0007 tuple) is untracked
  on the spot (swap-pop), and a market holding any state survives. One pass does valuation and
  cleanup; there is no `_sweepUntrackableMarkets` pass to pay for separately. Off-chain `eth_call`
  reads re-execute the (reverted) prunes each call — harmless and gas-free to the caller. (GMX
  comparison: GMX needs no tracked-market list because positions are enumerable from GMX's own
  DataStore; its `purgeInactiveTokensAndApps` is an owner action that drops apps with empty
  balances — see "App purge" below for how the Lighter branch makes that reachable.)

This design makes **untracked-position NAV risk structurally impossible for all EVM-initiated
flows**: the only way to trade a market through the pool is `createOrder`, which tracks it, and
the NAV loop only iterates tracked markets. The residual risk vector is API-key trading
(off-chain), which is why phase 1 excludes `changePubKey` — see [API_KEYS.md](API_KEYS.md).

`cancelOrder` / `cancelAllOrders` are forwarded unchanged (no NAV tracking impact).

**App-active vs tracked-markets visibility.** `getLighterTrackedMarkets` reads pool storage
unconditionally — it does not depend on the `LIGHTER_PERPS` application bit. So if the app bit
is ever cleared (e.g. by the owner calling `purgeInactiveTokensAndApps` on an empty Lighter
balance), clients can still read the tracked-market list, and any later `createOrder` keeps
working against it (the deposit flow re-activates the bit). This mirrors GMX, where the
tracked-markets storage likewise outlives the active-app bitmap.

The view lives in the **base `EApps`**, not `EAppsLighter`, deliberately: `ExtensionsMap` routes
the selector on every chain from shared map code (with the `type(IEApps).interfaceId` assert),
so the base answers it — returning empty arrays off-Lighter — instead of every other chain's
extension reverting on a routed selector. It returns each market together with its stored
`sizeDecimals`/`priceDecimals` (plus the in-flight bookkeeping fields) because those scales
are pool storage that any client decoding raw Core positions needs; a constants-table lookup
would work too, but the storage values are the ground truth the NAV loop itself uses.

### Market decimal scales: release-time constants, never caller input

Lighter stores order sizes and prices as integers on per-market scales. `size_decimals` (0–18)
converts a Core amount to base-asset units (sizeDecimals 3 → amount `1500` = 1.5 base);
`price_decimals` (0–16) does the same for prices (priceDecimals 2 → price `239976` = $2,399.76).
**Why two different scales**: they answer two different precision needs per asset. The size scale
sets the lot size of the base asset (ETH slices of 0.0001, BTC of 0.00001 — high-value assets
need fine slicing; DOGE at ~$0.08 needs none, whole coins); the price scale sets the tick
precision of the USDC quote (DOGE moves sub-cent, so 6 decimals; BTC is fine at 0.1 USDC ticks).
DOGE's `(0, 6)` is thus not an anomaly: `sizeDecimals = 0` means DOGE amounts are whole-coin
integers, and `priceDecimals = 6` gives micro-dollar price resolution. The NAV formula only ever
uses the **sum** `10^(sizeDecimals + priceDecimals)`, which converts `position × markPrice` into
1e6 USDC in one step.

READ_CORE does not expose the scales — the Lighter docs direct integrators to the off-chain
`orderBookDetails` Core API — and they are per-market (never reusable across markets). Because
NAV divides by `10^(sizeDecimals + priceDecimals)`, a wrong scale distorts pool NAV for **every**
token holder. An early iteration of this integration took the decimals as
`trackMarket(uint16, uint8, uint8)` owner inputs with only a range check — a typo or malicious
owner could misvalue every position by orders of magnitude. That design was rejected as
unacceptable. The current design:

- the scales come from the immutable `LighterConstants.marketDecimals` table, populated at
  release time from `GET /api/v1/orderBookDetails?market_id=N`:

  | Market | Symbol    | sizeDecimals | priceDecimals | Source                               |
  | ------ | --------- | ------------ | ------------- | ------------------------------------ |
  | 0      | ETH-PERP  | 4            | 2             | orderBookDetails, fetched 2026-10-20 |
  | 1      | BTC-PERP  | 5            | 1             | orderBookDetails, fetched 2026-10-20 |
  | 2      | SOL-PERP  | 3            | 3             | orderBookDetails, fetched 2026-10-20 |
  | 3      | DOGE-PERP | 0            | 6             | orderBookDetails, fetched 2026-10-20 |

  (Devnet exposes no public Core API; the values were fetched from Lighter mainnet, whose
  market configs mirror the devnet markets 0–3.)

- **On-chain consistency check (2026-10-23).** The table was cross-validated against live
  devnet READ_CORE market-info reads: each market's `indexPrice`/`markPrice` magnitude is
  realistic only under the table's `priceDecimals` (ETH `240040` → $2,400.40; BTC `816608` →
  $81,660.8; SOL `1667088` → $1,667.088; DOGE `80006` → $0.080006), and a live ETH-PERP
  position revalues to a NAV consistent with the observed price move (pool `0x7Bcea…6CB8`,
  `updateUnitaryValue` txs `0xfd01e437…4ace7` / `0x521a248f…7265`). The ETH row is therefore
  not "accidentally correct": the same check bounds every other row. (Prices are devnet values.)
- Any `marketId` absent from the table reverts `UnknownMarket(marketId)`. Adding a market is a
  code change shipping with the next adapter deployment — the same trust model as the
  whitelisted-selector set.

**What we need from Lighter (open question 6).** Every new Lighter perp market requires a
Rigoblock release (constants table + redeploy) before any pool can trade it — the scales are the
one market datum READ_CORE does not return, even though it already returns the market's prices
and minimums. Either of two additions to READ_CORE would remove this entirely: (a) include
`size_decimals`/`price_decimals` in the market-info read (`0x0005`), or (b) an aggregated perps
account-equity read (the Hyperliquid `accountMarginSummary.accountValue` equivalent), which would
additionally remove the 32-market cap and the tracked-markets bookkeeping. Until then the table
stays, with values re-verified at every release.

## NAV computation

LighterEVM has **no aggregated perps account-value read** (the Hyperliquid
`accountMarginSummary.accountValue` equivalent does not exist). NAV is therefore _computed_:

```
NAV_usdc = collateralBaseAmount                                  (READ_CORE 0x0001, 6-dec)
         + Σ_markets  positionValue(market)                      (only tracked, size ≠ 0)
         [+ in-flight adjustment, tx-status driven, ≤ 16 s window]

positionValue = markValue − signedEntryQuote
              + (marginMode == 1 ? allocatedMargin : 0)

markValue          = position × markPrice × 1e6 / 10^(sizeDecimals + priceDecimals)   (signed)
signedEntryQuote   = position > 0 ? entryQuote : −entryQuote
```

### Decimal scales (three different USDC scales coexist — this was a real bug source)

| Field                           | Scale                                       | Notes                                             |
| ------------------------------- | ------------------------------------------- | ------------------------------------------------- |
| `collateralBaseAmount` (0x0001) | 1e6 per USDC                                | shared cross/isolated collateral, used as-is      |
| `entryQuote` (0x0007)           | 1e6 per USDC                                | **entry NOTIONAL value, not a price** — see below |
| `allocatedMargin` (0x0007)      | 1e6 per USDC (since devnet 1.1.0; was 1e12) | isolated margin only; added back directly         |

The "12 decimals" figure in the pre-1.1.0 Lighter docs referred to `allocatedMargin` (and
Core's internal margin accounting); devnet 1.1.0 moved it to standard Core USDC base units
like every other USDC-denominated field. An early implementation treated `entryQuote` as an
entry _price_ and mixed scales; the fork test
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

- Isolated-margin positions add back `allocatedMargin` (6-dec USDC since devnet 1.1.0) because
  isolated margin is not part of the shared collateral balance. Cross-margin positions need no
  adjustment. Both margin modes are handled and unit-tested (long/short × cross/isolated).
- Unrealized PnL is mark-to-market: every NAV read revalues open positions at Core's current
  mark price against the frozen entry notional, so a position moving in price changes NAV on
  the next read. Unit tests cover PnL in both directions; the fork NAV test values a live
  tracked position against the devnet mark price.
- The in-flight amount is applied only while the transfer's `reqId` is in the expected
  pending/success state and within the 16 s window (see below).
- If the total is exactly zero: with an open position the pool reports a dust value of 1 (a
  zero-PnL open position must keep the app valued — otherwise `purgeInactiveTokensAndApps`
  could drop the app bit and orphan the position from NAV); with nothing held (no collateral,
  no open position, no in-flight amount) the branch reports an **empty balance list**, which is
  what makes the Lighter app purgeable at all (see "App purge" below).

**Trust assumption (vs Hyperliquid).** Position value uses **Core's own mark price**, which the
Core operator influences by design (mark pricing, backrunning, liquidations). This is a stronger
trust assumption than Hyperliquid's authoritative `accountValue`, and is the main reason the
32-market cap exists: NAV cost scales linearly with tracked markets (see below), and every extra
market is another mark-price surface. Documented for the audit; accepted for phase 1 because
LighterCore is itself the counterparty oracle for these positions.

**Mark-price availability.** Every perp market that exists in Core carries a mark price — the
market-info read (`0x0005`) returns `markPrice`/`indexPrice` as mandatory fields (they are `0`
only for spot markets, which the adapter rejects). This differs from the GMX episode where some
markets lacked Chainlink streams and feed addresses had to be hardcoded: Lighter's mark price is
not a per-market external dependency but Core-internal state that exists by construction with
the market. The residual risk is a market being delisted (read starts failing), which degrades
that position to zero-PnL rather than reverting NAV; the NAV loop then drops the stale entry on
its next pass.

**Worked example (live devnet reads, 2026-10-23, pool `0x7Bcea…6CB8`).** Short 0.008 ETH-PERP
(`position = -80` on sizeDecimals 4), entry notional `entryQuote = 320_000_000` ($320.00, i.e.
$40,000/ETH at entry), Core mark price `239976` ($2,399.76 on priceDecimals 2):

```
markValue = -80 × 239976 × 1e6 / 10^(4+2) = -19_198_080  ($-19.19808)
pnl       = markValue − (−entryQuote) = -19_198_080 + 320_000_000 = +300_801_920  ($+300.80)
NAV       = collateralBaseAmount + pnl  (+ isolated margin if marginMode == 1)
```

Cross-margin mode here, so no margin add-back. (Devnet mark prices move a lot between reads —
the position above entered at ~$40,000/ETH while the read-time mark was $2,399.76 — so the
example demonstrates the formula on real read values, not a point-in-time NAV reconciliation.
The pool's two `updateUnitaryValue` txs (`0xfd01e437…4ace7`, `0x521a248f…7265`) moved unitary
value off the 1 USDC seed by small amounts in line with mark-to-market PnL at their respective
times — on-chain confirmation that the end-to-end NAV path (auto-tracked market, mark price,
decimal scales) revalues live positions on every update.)

Funding payments are not observable on-chain since devnet 1.1.0: the position read no longer
carries `lastFundingRatePrefixSum`, and Rigoblock's NAV formula deliberately uses only
`entryQuote` vs `markPrice` — the mark price reflects the funding-adjusted exchange state at
read time. **Open question: confirm funding is settled into/through the mark or collateral
balance on LighterCore.**

### NAV routing: the computation lives in the extension (EAppsLighter)

`LighterLib` compiles into `EAppsLighter`, the chain-19529 member of the per-chain `EApps`
family (see below). The `LIGHTER_PERPS` branch of `EAppsLighter.getAppTokenBalances` calls
`LighterLib.getLighterBalances(address(this))` directly — the extension runs under delegatecall
in pool context, so it reads the pool's Lighter slot from storage and performs the READ_CORE
reads itself. No Authority round-trip, no adapter hop:

1. `MixinPoolValue` (implementation) calls `getAppTokenBalances(packedApplications)` on the
   pool; `MixinFallback` routes the selector through `ExtensionsMap` to `EAppsLighter` with
   `shouldDelegatecall = true`.
2. The `LIGHTER_PERPS` branch asserts the settlement lock (exempt when the transient
   nav-lock-exempt flag is set by `updateUnitaryValue`) and calls
   `LighterLib.getLighterBalances(address(this))`.
3. `LighterLib` reads the pool's tracked markets and in-flight accounting from
   `StorageLib.lighterSlot()` and computes the NAV from READ_CORE.

A standalone `getLighterBalances()` view existed in the first iteration (mapped by
`ExtensionsMap` via `IEAppsLighter`); it was removed on 2026-10-23 — it duplicated the NAV
branch exactly, was unused off-chain, and every mapped selector costs `ExtensionsMap` size.
Clients read the same valuation through `getAppTokenBalances(packedApplications)` (an
`eth_call` works fine on it despite the non-view signature: it makes no state writes in the
Lighter branch).

Security properties: write-mode access is unchanged (deposits/orders go through the
owner-gated delegatecall path); the settlement lock is asserted fail-closed in the branch before
any read; and — unlike the earlier Authority-routed design — NAV cannot be bricked by a
governance selector-mapping change: an extension's routing is immutable in the `ExtensionsMap`
bytecode, not upgradeable via Authority. This was the main motivation for the EApps split.

**Never-revert NAV reads (the pool-freeze fix).** A NAV revert does not just fail one read —
`updateUnitaryValue` is on the critical path of mint/burn, so a reverting Lighter branch freezes
the _entire pool_ for every token holder. That happened on the devnet on 2026-10-20 (post-mortem
below). The NAV path therefore degrades instead of reverting, matching the policy GmxLib has
always used for GMX reads:

- missing Core account → the branch contributes an empty balance list;
- missing/unreadable position on a tracked market → that market contributes 0;
- unreadable market info (mark price, e.g. a delisted market) → the position is valued flat at
  its entry notional (zero PnL) plus isolated margin;
- the tx-status read cannot fail per the docs (unknown reqIds return status 0), so the in-flight
  adjustment is exact whenever it applies.

The only remaining try/catch-style tolerance is therefore _absence handling per the documented
failure semantics_, not format tolerance: with the docs and the devnet now in agreement, every
read has a deterministic success shape (see the selector table).

Valuation degradation is one-directional-conservative in the only window where it can trigger:
while a transfer is within its 16 s settlement window, `assertNavUnlocked` already blocks
`updateUnitaryValue` for everyone except the exempt self-call, so the degraded reads only run
when NAV is allowed to settle anyway.

### App purge: tracked markets do not block it

`purgeInactiveTokensAndApps` (owner action on the implementation) drops an application bit only
when that app reports an **empty balance list** from `getAppTokenBalances(packedApps)`. Two
questions follow for Lighter:

- **Do tracked markets have to be removed before purging? No.** The tracked-market list is pool
  storage, not an application: `getAppTokenBalances` only evaluates the apps set in the packed
  active-application bitmap, so once the bit is dropped the tracked list is inert — it is read
  again only if a later deposit re-activates the bit (the same outlives-the-bit behavior as
  GMX's tracked-token storage). Purge requires only that the branch can report empty: no Core
  collateral, no open position/orders, no in-flight amount. Stale tracked entries are cleaned by
  the NAV loop itself on its next pass, so no owner-facing untrack method is needed.
- **Can the owner accidentally purge while a position or orders are open? No.** Any surviving
  tracked market (one with a position or open orders — precisely the entries the NAV loop does
  not prune) makes the branch report dust = 1 (non-empty) even when the mark-to-market total is
  exactly zero, so the purge condition `balances.length == 0` cannot be met with live state. The
  owner must close positions and orders and drain collateral first — the same trust model as
  GMX, where `purgeInactiveTokensAndApps` likewise relies on the app honestly reporting empty.
- **Negative account value.** A negative total (losses beyond collateral — `collateralBaseAmount`
  and the PnL sum are signed) is **returned as-is**, exactly like `HyperliquidLib` does with a
  negative HyperCore `accountValue`: the liability stays in pool NAV, the balance list is
  non-empty, and the app bit cannot be dropped while the pool owes money — depositors exiting at
  that NAV correctly absorb the loss, and the pool cannot be purged into hiding it. No clamping
  to zero or dust: that would overstate NAV and make the loss someone else's problem. Unit tests
  cover the negative path (`testGetLighterBalancesNegativeTotalReturnedAsIs`).

The first iteration's `dust = 1 whenever the Core account exists` made the Lighter app
**unpurgeable** (the account exists forever once created); the empty-when-nothing-held rule
above is the fix, and the zero-PnL dust exception keeps the purge path safe.

**Post-mortem: the 2026-10-20 devnet pool freeze.** After a pool's first successful Core
deposit, `updateUnitaryValue()` reverted with no revert data and the pool bricked completely —
deposits, orders, and mints all reverted, including for the owner. Root causes, both read-layer
strictness bugs (the deployed build predates the dual-format layer):

1. `coreAccountExists` envelope-decoded a devnet build that serves **raw** payloads, so the
   account-exists check consumed raw account words as a `(bool, bytes)` envelope.
2. The position read for a **tracked-but-never-traded** market failed the call outright (devnet
   signals absence by failing), and the NAV path reverted instead of treating it as "no
   position".

Fix: the deterministic read layer (docs and devnet now agree on shapes and failure semantics)
plus the never-revert degradation rules above. The frozen pool
(`0x07816c51…C9Be`, operator test pool) stays frozen **unless its owner calls
`upgradeImplementation()`** — the rewire below points the factory at the 4.6.x implementation,
and any pool whose owner upgrades gets the fixed read layer; until then it remains on the old
implementation (pool implementation adoption is owner-opt-in by design).

## Per-chain EApps split and ENavView removal (implemented 2026-10-20)

`EApps` was split so that each chain only pays the bytecode of the protocols it hosts, and a
single-chain fix stops forcing version bumps and redeploys on every chain:

- **`EApps`** (base, every chain): `GRG_STAKING` + `UNIV4_LIQUIDITY` branches.
- **`EAppsArbitrum`** (chain 42161): adds `GMX_V2_POSITIONS`.
- **`EAppsHyperliquid`** (chain 999): adds `HYPERLIQUID`.
- **`EAppsLighter`** (chain 19529): adds the `LIGHTER_PERPS` branch (settlement lock + NAV
  valuation, via `LighterLib` compiled into the extension).

`_handleApplication` is `internal virtual` in the base; subclasses handle their application and
`super`-call the base. All four share the same `EAppsParams` constructor and the same
`ExtensionsMap` selector routing (the map routes the union of selectors; a chain whose `eApps`
does not implement a selector simply does not answer it — e.g. `getLighterTrackedMarkets` is
only meaningful where `LighterLib` is compiled in). The deploy script picks the artifact by
`chainId` (`src/deploy/deploy_extensions.ts`).

**`ENavView` was removed entirely** (extension, interface, `NavView` library, `NavData` type,
ExtensionsMap wiring, deploy steps, tests): it duplicated the NAV aggregation for a DefiLlama
path that now reconstructs NAV manually and an SP1/zk-NAV path that was never implemented, and
it sat at the contract-size limit, forcing the Authority-routed NAV design described above.
The EApps write path remains the single NAV source of truth; clients can simulate the write path
(`updateUnitaryValue` / `getAppTokenBalances`) off-chain for free.

Cost, as predicted in the original postponed note: the same protocol `VERSION` now carries
different extension implementations per chain, and an extension change on one chain still forces
an implementation redeploy on that chain. Accepted: implementation redeploys are cheap
(operator opt-in upgrades) and the alternative (one monolith) re-creates the size pressure that
caused the NAV-routing bug in the first place.

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

The devnet RPC env variable is **`LIGHTER_DEVNET_RPC_URL`** — explicit devnet naming, so a
mainnet endpoint can never silently occupy the variable the tests read (unlike
`HYPERLIQUID_RPC_URL`, which is and always was **hyperEVM mainnet**, chain 999 — do not
assume otherwise from the absence of a "mainnet" infix). Foundry keeps its own `lighter` RPC
alias in `foundry.toml` resolving from `LIGHTER_DEVNET_RPC_URL`; the fork fixture forks
`"lighter"`. Hardhat's network for the devnet is `lighterevm-devnet` (chainId 19529), named
per Lighter's docs, and its URL is exactly `LIGHTER_DEVNET_RPC_URL` — nothing else (in
particular not `LIGHTER_DEVNET_EXPLORER_URL`, which is the blockscout API base used for
contract verification only). The verification URLs are `LIGHTER_DEVNET_API_URL` /
`LIGHTER_DEVNET_BROWSER_URL` — access-restricted, never committed. `.env.sample` documents
all of these.

**When a LighterEVM mainnet launches, do not repoint anything** — add a separate
`LIGHTER_MAINNET_RPC_URL` / `lighter-mainnet` endpoint, its own chainid constant and fork
tests (see the `foundry.toml` note). Three guards make a stale or misconfigured secret fail
loudly instead of testing the wrong chain: the fork fixture requires
`block.chainid == 19529` after forking, the live suite's setUp asserts the endpoint's
`eth_chainId` equals the devnet chainid, and CI only ever injects the secret via the
workflow `env:` mapping (`.github/workflows/ci.yml`). Like every other chain's fork suite, a
missing `LIGHTER_DEVNET_RPC_URL` fails at `createSelectFork` — the lighter suites never skip
silently.

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
   `EAppsLighter`, fail-closed) blocks NAV-dependent state changes — mint, burn, and other locked
   flows — for `_SETTLEMENT_WINDOW = 16` seconds after any recorded Core write, same-block
   exempt. This covers refund/delivery lag beyond the in-flight window. The tx-status read is a
   hard read: per the docs it cannot fail for a well-formed query (unknown reqIds return status
   `0`), so no failure tolerance is needed there.

The 16 s window is a starting value: **Open question 3 for the Lighter team —
what is the actual Core→EVM state-observation lag in EVM blocks?** On HyperEVM the window was tuned
against measured lag; on LighterEVM we cannot measure without sustained RPC access.

## EVM differences relevant to the integration

| Topic                                | LighterEVM behavior                                                              | Integration impact                                                                                                                                        |
| ------------------------------------ | -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| EIP-2718 deposit txs                 | No user-facing deposit transaction type                                          | Nothing to handle in the adapter                                                                                                                          |
| Type `0x7E` txs                      | Exogenous txs from Core system address `0x7fff…ffff` deliver withdrawals/refunds | Pool's USDC arrives asynchronously; no code path needed                                                                                                   |
| Precompiles                          | `0x6600…` range incl. READ_CORE                                                  | Standard `staticcall`; no special casing                                                                                                                  |
| CREATE2 / DELEGATECALL / EXTCODEHASH | No documented deviations                                                         | Proxy + adapter patterns unaffected                                                                                                                       |
| `block.number` / timestamps          | 1 s blocks                                                                       | Settlement window uses `block.timestamp`                                                                                                                  |
| Account activation                   | **None required** (vs Hyperliquid's builder requirement)                         | First deposit auto-creates the Core account; reads of a nonexistent account fail outright per the docs (which `coreAccountExists` treats as "no account") |

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

- `VERSION` is `4.5.0` (`MixinConstants.sol`); `ALighter._REQUIRED_VERSION = "4.5.0"`; the
  `pool.VERSION()` test assertion tracks it in the same PR. The devnet 1.1.0 reset (2026-10-26)
  wiped every previously deployed train (4.6.0–4.6.4 existed only on the old devnet), so after
  merging `development` (at 4.4.7/salt19) the unreleased train was renumbered to the next
  version/salt pair: 4.5.0 / `extensionsMapSalt20`. (History: 4.6.1 = ENavView removal +
  per-chain EApps split + deterministic-read `LighterLib`; 4.6.2 = view/method removals;
  4.6.3 = NAV-loop purge redesign; 4.6.4 = EOracle TWAP rounding fix, issue #967.)
- `extensionsMapSalt` is `extensionsMapSalt20`. The 1.1.0 read-ABI breaking changes (envelope +
  position layout) changed `LighterLib` → `EAppsLighter` and `LighterTypes` → `ALighter`
  (`_REQUIRED_VERSION` bump) → new ExtensionsMap → new implementation, all in the same train.
- Chain 19 529 added to `PRODUCTION_CHAIN_IDS` in `rocketh/config.ts` with the Safe singleton
  factory (preinstalled on LighterEVM → deterministic-address parity holds).
- `src/utils/constants.ts` chainConfig: WETH9 predeploy as wrapped native; zero
  oracle/staking/uniV4/posm/router/across/wormhole entries; devnet USDC.
- `hardhat.config.ts` `lighterevm-devnet` network + fee caps (`src/utils/networkFees.ts`: 1 gwei max /
  0.01 gwei priority), `foundry.toml` `lighter = "${LIGHTER_DEVNET_RPC_URL}"`, `.env.sample` entries.
- `src/deploy/deploy_extensions.ts`: chain-19529 branch skips Uniswap/0x/AGovernance (not
  deployed there) and deploys `ALighter`; the `EApps` artifact is selected per chain
  (42161→`EAppsArbitrum`, 999→`EAppsHyperliquid`, 19529→`EAppsLighter`, else base `EApps`).
  Selector registration in Authority is governance-driven (no `addMethod` in the deploy
  scripts): before pools can use the adapter on 19529, governance must register the five
  adapter selectors — `sendToCore`, `sendToEvm`, `createOrder`, `cancelOrder`,
  `cancelAllOrders`. (The former `trackMarket`/`untrackMarket` selectors were removed when
  tracking became automatic and untracking moved into the NAV loop (purge-in-place); the former
  `getLighterBalances` view needed no Authority mapping anyway and is gone from
  `ExtensionsMap` too — see "Trading flow".) NAV needs no Authority mapping: the
  `LIGHTER_PERPS` branch routes through the immutable `ExtensionsMap` to `EAppsLighter`.
- **Devnet manual wiring (2026-10-19, executed from the deployer key `0x080f…1fA6`).** The
  deploy scripts leave factory/Authority wiring to governance, and `setImplementation` is
  commented out in `deploy_extensions.ts`, so it was done manually after deployment:
  `factory.setImplementation(SmartPool)` (the factory still held its placeholder
  implementation; callable by the deployer because `registry.rigoblockDao()` = deployer),
  `authority.setFactory(factory, true)`, `authority.setAdapter` for AMulticall and ALighter,
  `authority.setWhitelister(deployer, true)`, then `authority.addMethod` for the ALighter
  selectors plus the three `multicall` overloads. All confirmed on-chain, and a smoke-test pool
  was created end-to-end: `0x1896095137d709a9f19534d3f273e39a1e662b2a` answers `VERSION()`.
  (Proxy delegatecalls into the new implementation; `registry.rigoblockDao()` = deployer gates
  `factory.setImplementation`, and `isWhitelistedFactory` gates `PoolRegistry.register`, which
  is why step 1/2 were prerequisites — not pool upgrades, no pools existed yet.) No
  `setImplementation → factory` Authority mapping was added: production mainnet maps nothing for
  `0xd784d426` either. `TokenJar` (`0xA0F9…2B37`, immutable in SmartPool) has no code on the
  devnet — non-blocking, it is only a funds recipient.
- **Devnet rewire executed after the 4.6.0 redeploy (2026-10-20, deployer key `0x080f…1fA6`).**
  Redeployed contracts (salt21 ExtensionsMap, `VERSION = "4.6.0"`): EOracle
  `0x19be5D4507ac0950C029e1595F88f8B604e48E7e`, EAppsLighter
  `0x5ab4f5D24f5Ab4b03a6936cE7136B3057371051C`, ECrosschain
  `0xE518b94306eFB9dD5C4640B52784BEDb3b6bb143`, ExtensionsMap
  `0x671453A588Dc8b20B6471C45678A69f313724B7B`, SmartPool
  `0x3D4aE9617f21EADa4ca5C8A3E6B1006E7287A60a`, ALighter
  `0x9F9596248500098c3ec044dD5905584F593185D1` (deploy tx
  `0xfb73dd1c3bfd3de3d022f5986a5ec9f32b4f62fa48e865c9bd9088c9088ec916`). The 4.5.0 deployment
  had registered eight ALighter selectors against the old adapter
  `0x84859B478Ca90300ac39BAE37BF3038d54Ba82EC`, including the removed
  `getLighterBalances(address)` (`0x432de12b`) and three-argument `trackMarket(uint16,uint8,uint8)`
  (`0x341a942b`). All eight were removed (`removeMethod(selector, oldAdapter)`) and seven
  re-added against the new adapter: `0xeed67f2c`/`0x60f502da`/`0x8a7da422`/`0x736fd6b3`/
  `0xa4b6f756`/`0xe0ad5442` (unchanged signatures) plus the new one-argument `trackMarket(uint16)`
  = `0xee814ef0` (`cast sig` verified; tx `0xc7126f127b1e78d69764b19349b22076a0df9fe8b6cc14c2ae2b7c47f915b4ac`).
  The new `getLighterBalances()` view (`0x58a5a2a4`) needs **no** Authority mapping — it routes
  through ExtensionsMap to EAppsLighter. `factory.setImplementation(0x3D4aE9617f21EADa4ca5C8A3E6B1006E7287A60a)`
  (tx `0x0621c03c50be3cec75d42962242349511eaf480df43ec4e6fea19afaa6f956e5`). Verified on-chain:
  all seven selectors resolve to the new ALighter, both rogue selectors resolve to zero, and the
  smoke pool `0x1896095137d709a9f19534d3f273e39a1e662b2a` was upgraded via `upgradeImplementation()`
  (tx `0xc97b63e9557cb368a16ca465286f0a7fcb566ee32bd8d9af52a22142267fa586`) and answers
  `VERSION()` = `"4.6.0"`. On the upgraded pool, ExtensionsMap-routed `getLighterBalances()`
  (`0x58a5a2a4`) returns an empty array without reverting for a pool with no Core account
  (tolerant read layer working); `getLighterTrackedMarkets()` (`0x5239dd83`) returns three empty
  arrays (raw returndata is a valid empty ABI encoding — the `cast` CLI's decoder trips on empty
  `uint16[]` tails, a client quirk, not a contract issue).
  Deploy note: the `deploy-contracts` wrapper prompts for gas-price confirmation on a TTY and
  cannot be piped (rocketh's prompt executor refuses non-TTY stdin); run the underlying task
  directly non-interactively instead:
  `env -u SOLIDITY_SETTINGS npx hardhat deploy --tags extensions --network lighterevm-devnet --skip-prompts`
  (the wrapper task does not forward `--skip-prompts`, and `--network lighter` is invalid — the
  network name is `lighterevm-devnet`; `lighter` is only the `foundry.toml` fork alias).
- **Devnet rewire executed after the 4.6.1 redeploy (2026-10-23, deployer key `0x080f…1fA6`).**
  Redeployed contracts (salt22 ExtensionsMap at `0x895B1082865E34194be6aF6119E31B7df58C090B`,
  `VERSION = "4.6.1"`): EOracle `0x488c965E5717371846eCcDe12D43059Da3050272`, EAppsLighter
  `0xBFA25521ab4C04F85aceE22B89Cc33FCD34F20E0` (deploy tx
  `0x35f1513c6569c0f308660b8cd3cf060292b86757b8feec7f1f74ef8f26673af3`), SmartPool
  `0x3a865A15660F0FABE7D551715e610CF2675B6406`, ALighter
  `0x9AB852ab02F0AaC804dCC7942Bf2e5A28Db9acAF` (deploy tx
  `0x614e18634476fdf77aaecd57e316c706296a6a4541a54d62dbc8ac751f6ee2a5`). The 4.6.0 adapter
  `0x9F9596248500098c3ec044dD5905584F593185D1` had seven selectors registered; all seven were
  removed and six re-added against the new adapter (`0xeed67f2c`/`0x60f502da`/`0x8a7da422`/
  `0x736fd6b3`/`0xa4b6f756`/`0xe0ad5442` = untrackMarket). The auto-track change makes the
  former `trackMarket(uint16)` selector `0xee814ef0` obsolete: it resolves to zero and stays
  unregistered. `authority.setAdapter(new ALighter, true)` =
  `0xc6c2849382cc3ebc01c6d0a4f5c3902eeb193997a1cf70edf4f84544c121e996`;
  `factory.setImplementation(0x3a865A15660F0FABE7D551715e610CF2675B6406)` =
  `0xd38933d2268a981043770e5728413e48c2dd28dfb33346f0dfd449c76995e57a` (verified via
  `factory.implementation()`); smoke pool `0x1896095137d709a9f19534d3f273e39a1e662b2a` upgraded
  via `upgradeImplementation()` (`0x6a3f398e7df72b585fa1667bfdf5166ed818b47a1d1efd5a26529192291e187f`)
  and answers `VERSION()` = `"4.6.1"`; ExtensionsMap-routed `getLighterBalances()` returns empty
  without reverting (no Core account on the smoke pool). The funded pool `0x7Bcea99B22Caa039ff282519d404dF38fbaC6CB8`
  is operator-owned and keeps its current implementation until its owner upgrades (adoption is
  owner-opt-in; its 4.6.0 implementation already carries the working read layer).
- **Devnet rewire executed after the 4.6.2 redeploy (2026-10-23, deployer key `0x080f…1fA6`).**
  Motivation: `getLighterBalances()` view and public `untrackMarket` removed (internal at-cap
  sweep instead), `ExtensionsMap` dropped the `IEAppsLighter` selector, READ_CORE reads decode
  the spec'd tuples directly (length checks removed), and the branch now reports empty when
  nothing is held so `purgeInactiveTokensAndApps` can drop the app. Redeployed (salt23
  ExtensionsMap at `0xc6588cfE51b9A748D75431932552a51b730e043E`, `VERSION = "4.6.2"`):
  EAppsLighter `0x29Def00CFd1A91EF04E221a79aBCdb668BB17688` (deploy tx
  `0x23e6a16dce7baa06d6cf41eed36dc3e1ad2bb0e4577d5a98ee7d4ed26ac31b4c`),
  ExtensionsMapDeployer `0x5f9D83b8669c6a2850EFd99949F7DF1031f3ee45` (deploy tx
  `0xfece9b38cff3eba0c58c0494cbb15c17a5f840b5111641a1dcb28a3adcd5876a`), ExtensionsMap
  deploy tx `0xce7b0770b8fd66d5239d2bf1f869399e5116648062eea417e03491527096ecd5`, SmartPool
  `0xB53318dc2C73A54cEc69Bf75637aF3C6fF2cCe79` (deploy tx
  `0x5c365cec5b3f7b65544f804b282145845f41dc37c7e56fe112b1924369966427`), ALighter
  `0x2C0d3bf602DF3dc74a6100e88bFbD08C210856E9` (deploy tx
  `0x7fe50c80737849455c9e0faf5dc6f7e84840d5110eea867d6177d3cd9e314fd0`). Authority: all six
  selectors of the 4.6.1 adapter `0x9AB852ab02F0AaC804dCC7942Bf2e5A28Db9acAF` removed
  (`0xeed67f2c`/`0x60f502da`/`0x8a7da422`/`0x736fd6b3`/`0xa4b6f756` txs
  `0x945562a7…`/`0x6c794a6d…`/`0x9637e48c…`/`0xeb15b5f0…`/`0x8ae936e7…`, untrack `0xe0ad5442`
  tx `0x9a8becbd…6929`), the five surviving writes re-added against the new adapter (txs
  `0x9af6ed18…`/`0x3ac8dfb9…`/`0x21dd72c5…`/`0xe129ea8c…`/`0xc734f1af…`), `setAdapter(new, true)`
  = `0x3ed11735ad269d06a7164046e3fe0665f377177b169de9ac1a9360957e9fc751`,
  `factory.setImplementation(0xB53318dc2C73A54cEc69Bf75637aF3C6fF2cCe79)` =
  `0x31796df15666a8f4702ce8434f524405c96522a134693a784473f487cf095a3e` (verified via
  `factory.implementation()`). Verified on-chain: all five selectors resolve to the new ALighter;
  both removed selectors (`0xe0ad5442`, and the long-obsolete `0xee814ef0`) resolve to zero; the
  removed `getLighterBalances()` view selector `0x58a5a2a4` reverts `PoolMethodNotAllowed` on the
  upgraded smoke pool `0x1896095137d709a9f19534d3f273e39a1e662b2a` (upgraded via
  `upgradeImplementation()`, tx `0x85d140a6da31e7a65373630755e75f5ac5d40f0cdcaaecfde61cd09aaac7c682`),
  which answers `VERSION()` = `"4.6.2"`; `getLighterTrackedMarkets()` still answers. The funded
  pool `0x7Bcea99B22Caa039ff282519d404dF38fbaC6CB8` sits on 4.6.1 (owner-upgraded) and works
  there — the owner must run one more `upgradeImplementation()` to pick up 4.6.2 (the live
  NAV-exactness test in `ALighterLive.t.sol` passes against it on either version, since the
  NAV branch is unchanged in shape).
- **Devnet rewire executed after the 4.6.3 redeploy (2026-10-23, deployer key `0x080f…1fA6`).**
  Motivation: purge-in-place redesign — the NAV loop itself untracks dead markets (allowed
  because `getAppTokenBalances` is non-view), the at-cap sweep was deleted, negative account
  values are returned as-is (Hyperliquid parity), `Position.position` renamed `size`.
  Redeployed (salt24 ExtensionsMap at `0xfA61b80d39F9f030deabC3EeDaAd93A54d7Ddf13`,
  `VERSION = "4.6.3"`): EAppsLighter `0x66718b5dD15f07851F8A7dfb029AD5BaAB5A0D34` (deploy tx
  `0x4d4156caed3370e3c8509aab1ed9d324cad499de49c04577076915a8039acc98`), ExtensionsMap deploy
  tx `0x24a577495beafffbe545b69797930014badcfb9fee62ebee73ad8f180cfad8d1`, SmartPool
  `0xD058F019A526aeE8a3C8b5aEBb6a055d8DC94876` (deploy tx
  `0x1697b82672022063daea0c6e54f74aa537cf6ffbb8e1312cda5795a8bec24c52`), ALighter
  `0x58c9A4E006fe5013CD613fD6790b8cCf498586fB` (deploy tx
  `0x75ac8e57785e681d6bde63e445cdce636a47eeeff4bb93f2e44d25e5864146ac`). Authority: the five
  selectors of the 4.6.2 adapter `0x2C0d3bf602DF3dc74a6100e88bFbD08C210856E9` were removed and
  re-added against the new adapter (`setAdapter` =
  `0xc3a12524fe1c93974c89c07ac10155d006a2fb7bb796f957f3634e657cd13d92`; remove/add txs
  `0xcb83c51d…`/`0x9feaad4a…`, `0x4b132529…`/`0xe8404d78…`, `0xe0f7b1a8…`/`0x132f2e81…`,
  `0x084b36fa…`/`0x7d450260…`, `0x8df1e08b…`/`0x6327d099…`),
  `factory.setImplementation(0xD058F019A526aeE8a3C8b5aEBb6a055d8DC94876)` =
  `0x73ff9a74b49b665dc2a0bdb8db59dbeeb57cbea279cf281a681f0636ae6bb560` (verified via
  `factory.implementation()`). Verified on-chain: all five selectors resolve to the new ALighter;
  smoke pool `0x1896095137d709a9f19534d3f273e39a1e662b2a` upgraded (tx
  `0x0842cc3bc81b2eb83e404760d361c7813862b06f8f350a74cdc1f929f2f1929c`) and answers
  `VERSION()` = `"4.6.3"`. The funded pool `0x7Bcea99B22Caa039ff282519d404dF38fbaC6CB8` needs one
  more owner `upgradeImplementation()` to pick up 4.6.3 (its 4.6.1 implementation keeps working;
  the live NAV-exactness test passes against it on any of these versions — the NAV shape is
  unchanged).
- **Devnet rewire executed after the 4.6.4 redeploy (2026-10-23, deployer key `0x080f…1fA6`).**
  Motivation: EOracle TWAP rounding fix (issue
  [#967](https://github.com/RigoBlock/v3-contracts/issues/967) — `getTwap` now rounds the mean
  tick toward negative infinity like Uniswap's `OracleLibrary.consult`) plus a hardening pass on
  the live NAV-exactness test. Redeployed (salt25 ExtensionsMap at
  `0x968C6fc2d5D0c4ACb5b7F33B988Fe9c163c9fECD`, `VERSION = "4.6.4"`): EOracle
  `0x2276ef1244e03Fb8768025F2B2ebE309464F522a` (deploy tx
  `0x540b21211f22b561fdb6c17259d094c299c18c19da41ef72f7f3c0dd38bc32c2`), ExtensionsMap deploy
  tx `0xa3be5861c12032f3943bff0d294d3097b8cdf1875d8666c547f55c83e17082cc`, SmartPool
  `0xd31ac5B09F9cF8fe69080bb2B0C9b0D0a6B2cd55` (deploy tx
  `0xc8f4179c716ca84af0ff7266d8197531942c09202f4a94d71029907fa6453ca5`), ALighter
  `0xd2c7090F36B263C3B2E4E5aA24fCe3Cc45C448F0` (deploy tx
  `0x52d5b49e86419ded6820b0dbc3e9315939db1bd1b77f1e9d8913b4d0fff3b9c4`; redeployed only
  because `_REQUIRED_VERSION` is compiled into its bytecode). Authority: the five selectors of
  the 4.6.3 adapter `0x58c9A4E006fe5013CD613fD6790b8cCf498586fB` were removed and re-added
  against the new adapter (`setAdapter` =
  `0x0269eb80437785ca7ad18f88ce7ec79f9b4e1a20f6948b662d16e66f3817893d`; remove/add txs
  `0x4c3a4ab3…`/`0xdc703e26…`, `0xdf040e2b…`/`0x69ddd059…`, `0xc41c791a…`/`0x604284c1…`,
  `0xf111d4ed…`/`0x351130bb…`, `0x7a63bcfd…`/`0x033550b3…`),
  `factory.setImplementation(0xd31ac5B09F9cF8fe69080bb2B0C9b0D0a6B2cd55)` =
  `0x637fec9592f5356a7416ad823e9df839e0ca9fb776e4442a2cc4bbf1cd2ac695` (verified via
  `factory.implementation()`). Verified on-chain: all five selectors resolve to the new ALighter;
  smoke pool `0x1896095137d709a9f19534d3f273e39a1e662b2a` upgraded (tx
  `0x4fae1aeaa242c12227397781b3bbc151facf421e41097a6a89449b4839dea2f6`) and answers
  `VERSION()` = `"4.6.4"`. Live-test note: the devnet produces blocks fast enough that the
  NAV-exactness reads can straddle every attempt, and pinned-block `eth_call` is rejected for
  READ_CORE ("live Core only serves blocks on the chain tip", verified directly). The test
  therefore brackets the pool's valuation read with mark-price reads before and after and
  passes as soon as the pool's NAV matches the recomputation at either observed price set;
  if no attempt matches, it falls back to an observed-skew bound — per tracked market,
  `(deltaTicks + 2) * |size| * 1e6 / 10^(sizeDecimals+priceDecimals) + 1`, where `deltaTicks`
  is the raw mark-price movement actually observed between the attempt's two brackets (a
  previous one-tick bound proved too tight: the devnet moved the mark 24 ticks within a
  single attempt, diff 1920 vs bound 122). The funded pool
  `0x7Bcea99B22Caa039ff282519d404dF38fbaC6CB8` needed one more owner
  `upgradeImplementation()` to pick up 4.6.4 (moot — the devnet was reset days later).

- **Devnet 1.1.0 reset + renumber to 4.5.0/salt20 and full redeploy (2026-10-27, deployer key
  `0x080f…1fA6`).** Lighter reset the devnet overnight (all contracts and balances wiped) and
  shipped devnet 1.1.0 with three breaking changes the integration now encodes: (1) READ_CORE
  returns the documented `(bool found, bytes data)` envelope on every read except 0x0000 —
  the dual-format parser is gone, `readPosition` returns a zeroed struct when `found == false`,
  and malformed/failed reads revert (`LighterReadFailed`); (2) the position read drops the
  leading `lastFundingRatePrefixSum` and reports `allocatedMargin` directly in 6-dec USDC
  (no `/1e6`); (3) void Core writes return `abi.encode(0)` and `createOrder` enforces Core
  admission on-chain. Since the wipe erased every chain that ever ran the 4.6.x train, the
  version was renumbered back to the next unreleased pair — `VERSION = "4.5.0"`,
  `extensionsMapSalt20` — after merging 43 `development` commits (the merge brought only
  dependency/package changes). Fresh deployment on the reset chain: Authority
  `0xe35129A1E0BdB913CF6Fd8332E9d3533b5F41472`, PoolRegistry
  `0x06767e8090bA5c4Eca89ED00C3A719909D503ED6`, Factory
  `0x8DE8895ddD702d9a216E640966A98e08c9228f24`, EUpgrade `0xF2210DbEa0d11a628b0c09a25E6e8c22cEa36c73`,
  EOracle `0x2276ef1244e03Fb8768025F2B2ebE309464F522a`, EAppsLighter
  `0x919B35900ed78C34363944C3151e1B2d1E74920f`, ECrosschain
  `0xE518b94306eFB9dD5C4640B52784BEDb3b6bb143`, EERC20 `0xF75251dEa6d1e11f5DbfcC180789aAdC4aE82B10`,
  ExtensionsMapDeployer `0x5f9D83b8669c6a2850EFd99949F7DF1031f3ee45`, ExtensionsMap
  `0x18b42b49192cc95AAaDfb57454Fa43e7A4Fe0B0D`, SmartPool `0xF987381064102D3625Adf41761117CF34A5339fb`,
  AMulticall `0xf837BD5854Cc76dD901FA5BBf029f3A92D2eF13a`, ALighter
  `0xAF15345724d560A7A1bFF088Fc6d8345dc82f6b5`. Authority wiring (all confirmed status=1 and
  verified on-chain): `setWhitelister(deployer, true)`, `setFactory(factory, true)`,
  `setAdapter` for AMulticall and ALighter, `factory.setImplementation(0xF987…)`, and
  `addMethod` for the three AMulticall selectors (`0xac9650d8`, `0x5ae401dc`, `0x1f0464d1` —
  the canonical `multicall(bytes32,bytes[])`; the web-chat integration's `0x1f0464d0` was a
  typo) plus the five ALighter selectors. New tester pool created at
  `0x0CD1eb6ACc12F24aD190a2708a7FEe3f23389adc` (create tx
  `0xf336c9335af1236291b319120c1470e664b39b5e1adb9dbd5075ab45033ddf4a`), answering
  `VERSION()` = `"4.5.0"`. USDC is not yet obtainable on the reset devnet (gated `mint`
  reverts), so the funded-pool live NAV-exactness test skips until the pool receives USDC and
  a `sendToCore` deposit. Fork pin bumped to `LIGHTER_BLOCK = 51_000`.

- Explorer verification: enabled with devnet 1.1.0 (Blockscout contract verification, per the
  changelog; the pre-reset build had it disabled). Hardhat 3's verify plugin (v3.1.0+) has native
  Blockscout support and does **not** accept Hardhat 2's `customChains` (that is `@hh2`-tag plugin
  syntax — see Blockscout's hardhat verification guide). The HH3 equivalent is a `chainDescriptors`
  entry in `hardhat.config.ts`, declared for chainId 19529 from the private env URLs
  (`LIGHTER_DEVNET_API_URL` / `LIGHTER_DEVNET_BROWSER_URL`; no explorer URL is committed to the
  repo). Verify with the provider-scoped subcommand, which leaves the Etherscan/Sourcify config
  untouched:
  `npx hardhat verify blockscout --network lighterevm-devnet <address> [constructorArgs...]`.
  `SOLIDITY_SETTINGS` must be unset for every call because the value committed in `.env` is a JS
  literal, not JSON, and crashes hardhat's config loader. Two gotchas from the 2026-10-27 session:
  the rocketh-style deployment artifacts store constructor args in `argsData` (not hardhat-deploy's
  `args`), so the plugin cannot auto-detect them — pass every constructor word explicitly, decoded
  from `deployments/lighterevm-devnet/<Contract>.json`; and address arguments must be EIP-55
  checksummed (use `cast to-checksum <addr>`), otherwise the plugin fails with HHE80017 "constructor
  parameter … cannot be encoded". Verified 2026-10-27: **all 13 contracts** (Authority, PoolRegistry,
  RigoblockPoolProxyFactory, ExtensionsMapDeployer, ExtensionsMap, SmartPool, EUpgrade, EOracle,
  EAppsLighter, ECrosschain, EERC20, AMulticall, ALighter).

  Three contracts could not go through the plain plugin command and were verified via the Blockscout
  v2 API directly (`POST $LIGHTER_DEVNET_API_URL/v2/smart-contracts/<addr>/verification/via/standard-input`,
  multipart with `compiler_version=v0.8.37+commit.f401782d` / `v0.8.17+commit.8df45f5f`,
  `license_type=apache_2_0`, `contract_name=<file>:<Contract>`, `constructor_args=<argsData>`,
  `files[0]=@<input>.json;type=application/json` — the `;type=application/json` is mandatory):
  - `RigoblockPoolProxyFactory`, `ExtensionsMapDeployer`: the plugin's local auto-detect step
    compares on-chain bytecode against every local artifact **including embedded creation-code
    metadata** (both contracts embed another contract's init code — proxy / ExtensionsMap — whose
    CBOR tail on-chain is the rocketh-canonical one, never reproducible by a fresh compile), finds
    no match, and fails with HHE80009 before ever submitting. The explorer itself masks metadata,
    so submitting a standard-json input succeeds (status shows `is_partially_verified: true`, as
    do the plugin-verified canonical-tail contracts — this is expected and matches mainnet's
    verification state).
  - `EAppsLighter`: its constructor takes a struct (`EAppsParams`), which the plugin CLI cannot
    encode (HHE80018/HHE80017). Same direct-API route with `constructor_args` = the 64-byte
    `argsData` (both params are zero on the devnet — no GRG staking / UniV4 POSM there).
  - `RigoblockPoolProxy` (the per-pool proxy, verified at the tester pool
    `0x0CD1eb6ACc12F24aD190a2708a7FEe3f23389adc`): the plugin refused without `--force`
    ("partially verified contract") even though the API reported no verification — a stale
    plugin-side check. `--force` + explicit `--contract` verified it (null constructor, so no
    args). Pool proxies are user-deployed, so each new pool's proxy address needs its own
    one-line verify; the input is the same every time.
    For the direct-API route, submit a **minimal** standard-json input (the contract's import closure
    only): the full-project 5.3 MB input was never picked up by the explorer's verifier, while
    ~100–300 KB closure inputs verified in minutes. Build the closure from
    `build/artifacts/build-info/<id>.json` (`input.sources`), resolving imports with solc's
    remapping semantics — contexts matter (`project/lib/universal-router/:permit2/=…` must win over
    the global `project/:permit2/=…` for importers under `project/lib/universal-router/`), and a
    hand-rolled resolver that gets this wrong produces a "Source not found" compile error that the
    explorer silently drops (the job just never appears). Sanity-check locally with
    `solc-0.8.37 --standard-json` that the output's `deployedBytecode` body (CBOR tail stripped)
    equals the on-chain code before submitting.

## Testing

| Suite          | File                                                                                                              | Status                                                                                                                                           |
| -------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| Unit (offline) | `test/extensions/ALighterUnit.t.sol`, `test/libraries/LighterLib.t.sol`, `test/extensions/EAppsLighterUnit.t.sol` | 58 tests, run in CI (the EAppsLighter suite deploys the full pool offline so the extension is covered even without `LIGHTER_DEVNET_RPC_URL`)     |
| Fork (devnet)  | `test/extensions/ALighterFork.t.sol` + `test/fixtures/LighterDeploymentFixture.sol`                               | **10 tests pass** at `LIGHTER_BLOCK = 51_000`; requires `LIGHTER_DEVNET_RPC_URL` — a missing or wrong-chain URL fails setUp loudly (never skips) |
| Live (devnet)  | `test/extensions/ALighterLive.t.sol`                                                                              | **2 tests** against the live devnet RPC (no fork, no mocks); setUp asserts the endpoint chainid is 19529                                         |

The live suite exists because READ_CORE (`0x6600…0000`) is a **native precompile with no code**
(verified via `eth_getCode` = `0x`) — Foundry's EVM cannot execute it even when forking — so it
calls the devnet RPC directly through the `vm.rpc` cheatcode instead of forking:

- `testLive_ReadCoreFormats` locks every response shape the integration relies on (0x0000/0x0001/
  0x0002/0x0004/0x0005/0x0007/0x0009) by decoding real precompile returns with the exact tuple
  types and asserting semantic invariants (USDC decimals 6, USDC token address, perp
  `marketType == 0`, account index consistency between 0x0001 and 0x0009, unknown-reqId status 0).
- `testLive_NavExactness` independently recomputes the NAV of the tester pool
  `0x0CD1eb6ACc12F24aD190a2708a7FEe3f23389adc` from live precompile reads and asserts **bit-exact
  equality** with the pool's on-chain `getAppTokenBalances` result. On the pre-reset devnet this
  was verified live against the funded pool `0x7Bcea99B…` (30 802 160 == 30 802 160, 6-dec
  USDC). Since the 1.1.0 reset it skips until the pool holds a Core account (funded via
  `sendToCore`) — USDC is gated on the reset devnet. Because the devnet mark price moves every
  block and the RPC serves `latest` only (no pinned-block `eth_call`), an attempt can straddle
  a block boundary and read two mark prices (one tick = 80 units for the pool's 0.008-size ETH
  short); the test therefore retries up to 5 times with fully fresh reads and requires exact
  equality on at least one attempt — a pass proves the pool's NAV path agrees with an
  independent recomputation at a single Core snapshot. It also skips transiently inside the
  16 s settlement window after a deposit/withdrawal.

The fork fixture mirrors `HyperliquidDeploymentFixture`: it uses live Authority/Registry/Factory
from `Constants` when present, else deploys local infrastructure, and registers the adapter
selectors (with the whitelister self-grant needed on live infrastructure). Foundry's EVM cannot
execute the client-side READ_CORE precompile when forking, so fork-suite precompile returns are
mocked with `vm.mockCall` (a wildcard revert in the fixture + per-test mocks). The mocks follow
the 1.1.0 envelope convention exactly: a successful read returns
`abi.encode(true, abi.encode(...fields...))`, and `abi.encode(false, "")` (or a reverted read)
signals a nonexistent account/market — matching `LighterLib._readCoreData`, which unwraps the
envelope and requires `found`. The `EvmInteropManager` (`0x6600…0001`) `sendToCore` return is
likewise mocked with an exact-calldata matcher — this asserts the adapter builds the correct
calldata (a wrong encoding misses the mock and hits the wildcard revert) — and the Core
entrypoint `createOrder` is prefix-mocked to return `abi.encode(0)`, the 1.1.0 void-write
response, because the real entrypoint enforces Core admission (a fork pool has no Core account).
This keeps the suite independent of the devnet's predeploy code, which can disappear without
notice (the first devnet build was wiped wholesale mid-integration; a later build may serve
state again at the same spec addresses).

The fork suite validates chain wiring, storage effects, flow guards, NAV valuation (via the
`EAppsLighter` branch of `getAppTokenBalances`), the NAV-loop purge, the settlement lock, and
adapter calldata construction. Live precompile behavior is covered by the live suite above.

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
- [x] createOrder auto-tracks its market (O(1) mapping check); untracking is internal-only in
      the NAV loop (no position AND no open orders required); untracked positions impossible
      via EVM flows
- [x] App purge reachable: branch reports empty when nothing is held, dust = 1 while any market
      with position/orders survives (zero-PnL position cannot be orphaned by
      `purgeInactiveTokensAndApps`)
- [x] Negative account value returned as-is (Hyperliquid parity): liability stays in NAV,
      non-empty list, app unpurgeable while negative
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
   market info (selector `0x0005`)? Rigoblock hardcodes them in the release-time
   `LighterConstants.marketDecimals` table (never caller input), so this is no longer an
   operator-error surface — but every new market requires a Rigoblock release to be tradeable.
   Exposing the scales on-chain would remove the table and the `UnknownMarket` gate entirely;
   an aggregated perps account-equity read would remove both and the 32-market cap (open
   question 2). Please also confirm the table values against the devnet's `orderBookDetails`
   once a Core API is reachable there (values were sourced from mainnet; see "Market decimal
   scales").
7. **Funding model**: is funding settled through the collateral balance or the mark price? Since
   devnet 1.1.0 the position read no longer carries `lastFundingRatePrefixSum`, so funding is not
   observable on-chain at all — Rigoblock's NAV reads mark price minus entry notional, so funding
   must be visible in one of those for exact valuation.

## References

- Lighter EVM docs: https://apidocs.lighter.xyz/docs/evm-introduction
- Lighter contracts (devnet branch, moving target): https://github.com/elliottech/lighter-contracts
- Hyperliquid integration (pattern source): [docs/hyperliquid/INTEGRATION.md](docs/hyperliquid/INTEGRATION.md)
- API keys analysis: [API_KEYS.md](API_KEYS.md)
