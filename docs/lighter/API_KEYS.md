# Lighter API Keys — Analysis for the Peer-Project Request

**Context.** A peer project (currently on Lagoon Finance vaults, trading LighterCore perps via API
key from tools in `tradingstrategy-ai/web3-ethereum-defi`) asked to migrate to Rigoblock _with the
ability to keep trading directly on LighterCore via API key_, because their trading systems are
wired to external tooling that cannot easily be adapted to send EVM transactions.

This document explains how Lighter API keys work, why Rigoblock's Lighter integration (phase 1)
does **not** expose them, what tradeoffs that creates, and the options going forward — so the peer
can make an informed decision, including whether to adapt their tooling to `lighterEvm` instead.

Related: [INTEGRATION.md](INTEGRATION.md) (integration design), and the
[Hyperliquid API-key precedent](docs/hyperliquid/INTEGRATION.md) (same exclusion was made there).

## How Lighter API keys work

On LighterCore, an account's authority is its key material. `EvmToCoreEntrypoint` (predeploy
`0x6600…0009`) exposes:

```solidity
function changePubKey(
  uint48 accountIndex,
  uint8 apiKeyIndex,
  bytes pubKey
) external returns (uint64 reqId);
```

Registering a public key this way authorizes **off-chain** requests signed with the corresponding
private key to act on the account — placing/cancelling orders through Lighter's API/WebSocket,
bypassing the EVM entrypoint entirely. Multiple key slots (`apiKeyIndex`) can exist per account.

Note this is a different (and simpler) threat surface than Hyperliquid's builder/whitelist
mechanism: any key registered on the pool's Core account can trade **any market** the account can
reach, with no on-chain trace beyond the resulting Core state.

## Why phase 1 excludes `changePubKey`

Rigoblock's pool NAV is computed **on-chain** during `updateUnitaryValue`, which every mint/burn
depends on. The Lighter NAV loop (see [INTEGRATION.md](INTEGRATION.md)) sums the shared collateral
plus the value of **tracked markets only** — a deliberate, capped set in pool storage that the
adapter validates (`MarketNotTracked` revert) for every EVM-initiated `createOrder`.

An API key breaks that invariant at a single point:

1. Operator (or anyone they hand a key to) trades a **non-tracked market** off-chain.
2. The position is real Core state, collateral moves, but the NAV loop never sees it.
3. Mint/burn prices are now wrong — new depositors can dilute or extract value from existing
   holders (classic NAV-integrity failure), in both directions depending on PnL sign.

There is no purely on-chain fix for this as long as (a) keys can trade arbitrary markets and
(b) NAV is computed on-chain. The only robust mitigations are procedural (pre-track every market
the key may ever trade — fragile, unenforceable) or architectural (off-chain NAV with a trusted
valuation manager — explicitly out of scope; it changes Rigoblock's security model entirely).

**Decision (phase 1): the adapter does not expose `changePubKey`.** Without it, registering an API
key on the pool's Core account requires a direct call to the predeploy from the pool, which only
the pool owner could perform via raw `delegatecall` tooling outside the adapter — i.e. an explicit,
unsupported act, not a supported feature.

## Why the peer's current (Lagoon) setup tolerates this — and why it doesn't transfer

The peer's current guard (`contracts/guard/src/lib/LighterLib.sol` in `web3-ethereum-defi`) scopes
on-chain custody only:

- Whitelisted selectors are exactly `deposit`, `withdraw`, `withdrawPendingBalance` on the L1
  ZkLighter contract; receivers must be on the guard's allowlist. Trading selectors
  (`createOrder`) and `changePubKey` are **explicitly out of scope** — the source comments say
  key rotation is "a follow-up needing an account-index policy".
- **NAV is computed off-chain** by a trusted valuation manager (Lagoon model), which _can_ see
  API-key trades through Lighter's off-chain APIs and price them. The on-chain share token is only
  as good as that off-chain valuation's timeliness and honesty.

Rigoblock's model is the opposite: NAV is trustless and on-chain. Everything the Lagoon guard can
afford to ignore (untracked positions, off-chain valuation lag, valuation-manager trust) becomes a
real exploit path in a Rigoblock pool. **Their acceptance of API-key trading does not transfer to
us**, and should not be read as evidence that it is safe for an on-chain-NAV vault.

## The key enabler: deposits skip the spot route on LighterEVM

On Hyperliquid, an EVM-only trading flow forced value through the spot account and required
careful position/market accounting. On LighterEVM, `EvmInteropManager.sendToCore(...,
RouteType.Perps)` moves USDC **straight into the perps margin route** — no spot step, no account
activation, first deposit auto-creates the Core account.

Consequence: **trading through `lighterEvm` alone is a complete, viable flow today** — deposit,
trade (market pre-tracked by the operator), cancel, withdraw, all from the pool owner's EVM
transactions, all NAV-covered by construction. The peer's stated reason for API keys ("our tooling
can't send EVM txs") is the only remaining gap, and it is on their side.

## Options going forward

### Option A — trade via `lighterEvm` only (recommended; implemented in this PR)

- The peer's systems adapt to send transactions to `lighterEvm` (standard JSON-RPC) instead of
  Lighter's off-chain API. `createOrder` on the entrypoint predeploy accepts the same order
  parameters; 1-second blocks make the latency profile far better than mainnet L1.
- NAV integrity is guaranteed structurally; no disclaimers needed; no cap surprises.
- Effort: their tooling swaps an API client for an RPC client. Lighter's own docs
  (https://apidocs.lighter.xyz/docs/use-with-ai) target exactly this kind of programmatic EVM
  usage.

### Option B — enable API keys later, with operator discipline (possible follow-up)

If the peer cannot adapt their tooling, a future adapter version could expose `changePubKey` under
strict rules:

1. **All markets the key may trade must be tracked first** (`trackMarket`); the adapter documents
   that untracked-market trading via key breaks NAV and is solely the operator's responsibility.
2. Pool-level disclaimer surfaced in the UI/API: _"This pool trades via Lighter API keys. Only
   pre-tracked markets may be traded; positions in untracked markets are invisible to NAV and can
   be exploited by depositors/withdrawers."_
3. Consider pairing with a conservative mint/burn settlement lock, so a key trade cannot be
   front-run against a stale NAV within the same settlement window (the window already exists;
   key trades wouldn't extend it, which is itself a residual risk).
4. Consider a governance-gated "API-key mode" flag in pool storage so key usage is visible to
   depositors (signal, not prevention).

Even with all of the above, option B keeps an _unenforceable_ invariant (the key can trade anything
off-chain), so it should be opt-in, prominently flagged, and audited before shipping.

### Option C — hybrid: custody in Rigoblock, trading in an off-chain-managed wrapper

Not recommended: reintroduces trusted off-chain valuation (Lagoon model) and gives up Rigoblock's
core differentiator.

## Suggested talking points for the peer (Option A)

- LighterEVM is built for exactly this: same order surface (`createOrder` params are identical),
  standard JSON-RPC, 1 s blocks, and deposits go straight to the perps route — no spot accounting,
  no activation step.
- Their existing calldata-building logic ports 1:1; only the transport changes (REST/WS → RPC).
- NAV integrity becomes a non-issue instead of a permanent operational disclaimer.
- They keep all existing LighterCore features reachable from the EVM entrypoint (market/limit/
  trigger orders, reduce-only, cancels), so trading-strategy expressiveness is unchanged for perps.
- Rigoblock gains a clean, auditable integration; they gain a vault with on-chain-verifiable NAV
  instead of a trusted valuation manager.

## Bottom line for the business decision

- Phase 1 (this PR): **Option A only.** The integration is complete, testable offline, and safe by
  construction. No API keys anywhere.
- If the peer confirms they can route orders over RPC: done — the migration is unblocked with zero
  NAV risk.
- If they hard-require API keys: Option B is a scoped follow-up with the mitigations above,
  explicit operator responsibility, and audit attention — and we should ask _why_ their tooling
  cannot send RPC transactions, since that constraint is the sole blocker for the safer design.
