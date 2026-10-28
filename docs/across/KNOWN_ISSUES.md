# Across Integration — Known Issues and Accepted Design Decisions

This document records known limitations and accepted properties of the cross-chain
Virtual Supply (VS) model (`AIntents` / `ECrosschain`) so that recurring security
reviews do not re-litigate settled questions. Each entry states the behavior, the
measured impact, why it is accepted, and what would change the disposition.

For the performance model see [PERFORMANCE.md](./PERFORMANCE.md). The regression
tests referenced below live in `test/debug/PoCVsRoundTrip.t.sol` (mainnet + Base
forks, real Across `depositV3` and MulticallHandler fills).

**Dispositions at a glance:**

- **W21 residual** (reported by pismol): accepted model property. Documented, no
  code change, no urgency. Residuals are bounded, redistributive, and exactly
  relievable while the sibling chain holds funds.
- **TS = 0 return trap** (found during W21 edge-case analysis): no funds at risk;
  a confirmed operator workaround recovers everything; on-chain fix drafted below,
  **not urgent**, scheduled for a future adapter train with a dedicated review
  session.
- **W22 — stray-balance capture via permissionless first-activation** (reported by
  deviykee): **accepted design consequence** of the Jan 2026 zero-supply-DOS fix,
  severity **Informational**, no code change, no payout. The fix deliberately
  changed stray allowlisted balances from "donate reverts" to "enter NAV on first
  activation"; a JIT minter can capture the resulting unitary-value jump. This is
  a redistribution of a balance already treated as lost/donated, bounded by
  `minPeriod`. The external Known Issues wording that said stray tokens "stay lost"
  is outdated and has been corrected below.
- **W23 — sentinel unitary value during non-positive NAV** (reported Oct 2026):
  **accepted limitation**, severity **Informational**, no code change, no payout.
  When `netTotalValue <= 0` the implementation clamps `unitaryValue` to the
  sentinel `1` as burn-side protection. Three operations (mint, source debit,
  destination credit) divide by that sentinel without a guard, producing
  share/VS inflation or deflation. Reachable only when the pool is already
  insolvent; no deployed pool is currently in that state.

## W21 — Round-trip VS residual under price moves (accepted model property)

**Reported by:** pismol (Oct 2026). **Status:** acknowledged, documented. No code
change. The reporter's PoC (`reports/W21_TEST_DIFF.patch`) was independently re-run
against current `development` and current fork pins: 2/2 tests pass, reproducing the
reported signs and magnitudes (destination VS ≈ −$81k, phantom NAV ≈ $82k, 163 bps
|VS|/TS → 1.72% locked tail, source VS ≈ +$99.9k pinned at par, zero-residual
control).

### Behavior

A Transfer round trip (outbound leg + return leg) that spans a NAV move of the pool's
holdings leaves a **residual VS on each participating chain**. The sign and size
depend on the direction of the move and on which chain's NAV moved during the bridge
window:

- The chain whose unitary value **rose** during the window ends with **negative VS**
  (if it originated the round trip): unitary value is overstated, total burn claims
  exceed physical assets ("phantom NAV"), and `NavImpactLib.validateSupply` pins the
  burn tail at `totalSupply − 20·|VS|/19` (`EffectiveSupplyTooLow` beyond it).
- The mirror chain ends with **positive VS**: unitary value is understated and the
  residual value is stranded (no holder path converts VS into claims); it silently
  accrues to future minters on that chain.

### Mechanism

Each leg is NAV-neutral **at its own execution-time unitary value** by construction.
A leg books a share count `V / u` — outbound at the initiation snapshot `u₀`, inbound
at the arrival snapshot `u₁`. A round trip therefore restores `V/u₁` claims after
removing `V/u₀`, and any move of the pool's own NAV between the two snapshots strands
`V·(1/u₀ − 1/u₁)` shares. The residual has exactly **two drivers**, and only two — a
change in the originator chain's unitary value between its two snapshots:

1. **Market repricing while value is in flight** (the common case). Two sub-channels,
   both following `V₀/u₀ − V₁/u₁` on the originator:
   - **(a) The originator's remaining book reprices** — the pool keeps volatile assets
     that move during the window, moving its unitary value between snapshots.
   - **(b) The transferred asset itself reprices** — the originator converts to /
     already holds the volatile asset, transfers it away, and is left holding only
     the base stablecoin (unitary value pinned at par), but the returned value
     `V₁` differs from the departed `V₀`. The residual is then exactly
     `−(V₀−V₁)/par`: the originator over-claims by the full P&L of the in-flight
     position on a loss (burn pin, phantom NAV) or strands the gain on a win. This
     is the researcher's scenario (verified: residual equals `−(V₀−V₁)/par` to the
     unit) — and it does not require cross-chain oracle divergence.
2. **Operator NAV actions mid-window**: a Sync donate (or any NAV-changing operation)
   on the originating chain between initiating a Transfer and its return leg
   completing. Verified with a pure-USDC round trip and zero market movement: a
   100k USDC mid-window donate created a −22,220-share residual (~$25k over-claim)
   where the static control is exactly 0.

Consequently, a pool holding **only its base stablecoin and transferring that
stablecoin is immune to driver 1** — unitary value is pinned at par, so both
snapshots coincide and market moves cannot strand anything. It is **not** immune to
driver 2. Neither driver requires an attacker, crafted parameters, or oracle
manipulation — ordinary market movement or an ordinary operator action during an
in-flight round trip suffices. Keeping NAVs "in sync" across chains does not prevent
it, and any NAV-changing action on the originating chain mid-window strictly worsens
it (measured: 2.8× worse at +10%).

### Measured impact (fork tests, `test/debug/PoCVsRoundTrip.t.sol`)

Scenario-dependent — scales with the moved fraction and the share of NAV held in
assets that reprice during the window:

| Move         | Residual VS (originating chain)         | Locked burn tail         | Phantom NAV |
| ------------ | --------------------------------------- | ------------------------ | ----------- |
| 0% (control) | exactly 0                               | none — full supply burns | $0          |
| +10%         | −1,998 shares (~$12.5k on a $1.5M pool) | 0.84% of supply          | $12,498     |
| +25%         | −4,712 shares                           | 1.98% of supply          | $31,241     |
| +50%         | −8,613 shares                           | 3.63% of supply          | $62,503     |

An extreme boundary case (a chain whose effective supply is ~100% virtual returns
everything over a +10% move) strands the appreciation as positive VS on the
all-virtual chain ($5.42M holderless) and leaves the originator at **64.5% asset
coverage** of its claims. This configuration requires the pool to hold essentially
all claims virtually and is not the expected operating mode.

### What does NOT happen

- The pool is **never fully stuck**. Mints and donations keep working with negative
  VS in place (they relax or leave unchanged the `validateSupply` constraint); only
  the burn tail past the pin reverts. Burns are the only supply-shrinking operation
  and are checked post-decrement, so the invariant cannot be ratcheted past the pin.
- **Sync transfers do not restore coverage.** The over-claim ratio
  `claims/assets = TS/(TS+VS)` is invariant to the asset level: a Sync transfer out
  removes assets and unitary value proportionally, leaving the ratio and VS
  byte-identical (measured: 80 bps over-claim before and after a 50k Sync-out at
  +10%). Only an inbound Transfer moves the ratio toward par.
- **NAV parity across chains is not required and does not prevent the residual.**
  The model prices each chain locally and tolerates permanently divergent per-chain
  NAVs between operator rebalances (different TWAPs, fees, timing). Verified with
  mirror pools under a symmetric move: unitary values stayed within ~1.35% at
  every checkpoint while the residual appeared anyway. Nor does the periodic
  rebalance Sync fix it — see the realistic-cycle finding below.
- Positive VS has no enforcement effect at all (`validateSupply` only fires on
  negative VS).
- No user funds can be stolen and no attacker profits; the harm lands on the pool's
  own holders (tail lock, first-come-first-served exits at an overstated unitary
  value).

### Realistic-cycle finding (sync does not fix the residual)

Measured end-to-end (`test_RealisticCycle_SyncRebalance_CreatesResidual`): outbound
Transfer, performance accrues on the destination chain's holdings only (277 bps NAV
divergence), operator executes the documented rebalance — exact equalizing Sync of
Δ = 19,997 USDC, NAV parity restored to 0 bps — then the return leg. Results:

- Without the sync the residual is exactly 0 on the originator and +1,350.0 raw-M on
  the destination. The rebalance sync does not eliminate the imbalance: it moves the
  originator's NAV between its two snapshots, creating a residual of −818.8 raw-M
  there, and the two chains end mirror-stranded (−818.8 / +818.8, sum exactly 0 —
  the sync achieves global conservation and perfect NAV parity, but splits the
  imbalance equally instead of removing it).
- Coverage ratios are invariant throughout (Sync writes no VS). Magnitude scales as
  ≈ moved value × sync amount, so small cycles strand small residuals.

Implication: there is no operator sequence that both maintains the documented
periodic NAV equalization and avoids the residual — only rebalance when no Transfer
is in flight, and relieve pins with inbound Transfers.

Direction of the equalizing Sync matters, measured: a Sync that DRAINS the pinned
chain's NAV before the return leg shrinks its residual (loss case: originator at par
sends to the loser chain; originator residual −68.17M → −37.55M raw, NAV parity
restored to 0 bps, residuals become mirror images) — but it cannot remove it, and
the mirror residual on the other chain grows correspondingly. A Sync that RAISES the
pinned chain's NAV (gain case, funds flowing in) creates or worsens the residual
(measured 2.8× at +10%). The residual is conserved across the pair up to the
cross-leg oracle basis: the sync redistributes, never eliminates.

### Single-supply-chain geometry — the zero-tolerance return trap

Measured in `test_SingleSupplyChainGeometry_WethRoundTrip` (all supply on the
originator; the destination burned to TS = 0, assets = 0; full-WETH Transfer out;
±10% move; with/without pre-return sync):

- **The return leg itself reverts in 3 of 4 variants.** With `totalSupply = 0` on
  the sending chain, `NavImpactLib.validateSupply` allows ZERO negative VS: the
  constraint `|VS|·20 ≤ TS·19` collapses to "VS must not be negative at all".
  Integer truncation in the share math (`u = floor(NV·10^d/ES)`,
  `burnt = floor(V·10^d/u)`) makes a few units of negative drift essentially
  certain once any price move has occurred, so the initiation reverts
  `EffectiveSupplyTooLow` and **the in-flight funds cannot be returned at all** —
  they sit on the destination chain with its positive VS, while the originator
  keeps its negative VS and its holders burn down to the pin. Only the no-move
  control cancels exactly (VS = 0 both chains, everything burns). The one completing
  moved variant (loss + pre-return sync) leaves a positive residual of +35.9 raw-M.
- **The trap is reachable without operator error:** holders of one chain can simply
  burn everything (allowed while VS > 0), and a later return initiation then bricks.
- **Remedies in this geometry:** the inbound-Transfer unstick is impossible (the
  sibling chain holds nothing — the real initiation reverts ERC20-insufficient-
  balance). The only escapes: an **implementation upgrade** resetting the VS slot
  (verified via `vm.store` emulation: originator burns fully, but the WETH left on
  the supply-less chain ≈ $692k at test scale strands as fresh-minter sweep
  surface), or **external money** bootstrapped into the empty chain (a new holder
  minting real funds gives the return leg TS-slack; measured operator net cost
  ≈ 65.2e9 USDC for a 69.2e9 hole at test scale, leaving a small unburnable husk).

**Operational rule (until the fix ships):** if a return leg from a zero-supply chain
reverts, do not retry the full amount — see the confirmed workaround below. With any
TS > 0 the return leg has proportional slack and completes.

**Root cause (why the mismatch exists at all):** the spec's formulas are integer
operations — mint writes `floor(V·10^d/u)`, burn writes `floor(V·10^d/u)`, NAV is
`floor(NV·10^d/ES)` — and claims are re-derived from value ÷ price at every leg
rather than tracked as ledger entries. Composition of independently rounded
re-derivations does not cancel: worked example with test values (+10% move,
M = 761,105,872,903 shares minted): the oracle truncates the returned value
(`…193.3 → …193`), the NAV update floors `u_B` to 1,099,999 instead of 1,100,000,
and the burn against that one-unit-low price lands 691,914 shares ABOVE the
outstanding VS — 0.00009% of supply, economically nothing, fatal only because the
TS = 0 tolerance is zero. At zero performance every intermediate is bit-identical
and all divisions are exact, which is why the control unwinds perfectly.

**Operator workaround (confirmed in `test_TsZeroTrap_PartialReturnPlusSync`, works
today, no code change):** initiate a PARTIAL return sized to burn exactly the
outstanding VS, then Sync out the dust. Sizing is deterministic same-block: binary-
search the WETH amount against the pool's own `convertTokenAmount` +
`unitaryValue` (the exact math `_handleSourceTransfer` runs); the exact-equality
window measured ~4.5×10^8 wei wide. Measured results: the sending chain unwinds to
VS = 0 exactly and zero assets (the dust sync succeeds — `validateNavImpact`
bypasses tolerance when effective supply ≤ 0), and the originator ends precisely as
a successful full return would: **gain case — positive residual, no pin, 100% of
supply burns with zero reverts; loss case — the documented negative residual class,
95% of supply burnable vs ~47% while trapped.** The gain case is fully resolved by
operator action alone; the loss case reduces to the residual, which still needs an
upgrade reset or external money because the sibling chain is empty.

**Disposition: no code change required for fund recovery — workaround confirmed;
fix specified below, NOT urgent, scheduled for a future adapter train.**

Rationale for "not urgent": no funds are ever at risk or unrecoverable. The
confirmed workaround recovers 100% of assets to the originating chain with ordinary
operator actions (no external money in the gain case; 95% exitability plus the
already-accepted residual class in the loss case, whose remainder is upgrade- or
bootstrap-remediable). The trap additionally requires a specific geometry — the
returning chain at `totalSupply = 0` — AND a price move during the flight; at zero
performance the unwind is exact. It should nonetheless ship in the next routine
adapter train rather than linger, because single-supply-chain operation is the
standard mode ("multi-chain from genesis" is explicitly supported,
`test_PerformanceAttribution_ZeroRealSupplyReceivesTransfer`) and an on-chain fix
removes the manual sizing procedure.

**Fix draft (for review in a dedicated session — NOT merged).** In
`AIntents._handleSourceTransfer` (`AIntents.sol:245-263`), clamp the burn to the
outstanding positive VS when total supply is zero:

```solidity
function _handleSourceTransfer(
  AcrossParams memory params,
  uint256 scaledOutputAmount
) private {
  uint256 outputValueInBase = _getOutputValueInBase(params, scaledOutputAmount);
  require(outputValueInBase > 0, ZeroConvertedValue());
  NetAssetsValue memory navParams = ISmartPoolActions(address(this))
    .updateUnitaryValue();
  uint8 poolDecimals = StorageLib.pool().decimals;

  // shares = outputValue / unitaryValue
  int256 burntAmount = ((outputValueInBase * (10 ** poolDecimals)) /
    navParams.unitaryValue).toInt256();

  // TS == 0 with positive VS: a computed burn beyond the outstanding VS is
  // truncation noise — no local holders exist whose claims could be reduced.
  // Clamp so the leg completes with VS == 0 instead of reverting.
  if (ISmartPoolState(address(this)).getPoolTokens().totalSupply == 0) {
    int256 outstandingVs = VirtualStorageLib.getVirtualSupply();
    if (outstandingVs > 0 && burntAmount > outstandingVs) {
      burntAmount = outstandingVs;
    }
  }

  // Write negative VS (shares leaving this chain → reduces effective supply)
  (-burntAmount).updateVirtualSupply();

  // Validate effective supply is still above minimum threshold after VS update.
  NavImpactLib.validateSupply(
    ISmartPoolState(address(this)).getPoolTokens().totalSupply,
    VirtualStorageLib.getVirtualSupply()
  );
}
```

Effect: the TS = 0 return burns `min(computed, outstanding)` → VS = 0, leg completes,
funds return — the on-chain equivalent of the confirmed workaround, sub-unit
conservative on the booking. `validateSupply` still runs after the write and still
guards every TS > 0 path unchanged.

**Alternative fix design (root cause — candidate for the same session):** compute the
burn directly against total assets instead of through the floored unitary value:

```solidity
// sharesLeaving = value / netTotalValue * effectiveSupply  (single division)
int256 effectiveSupply = int256(totalSupply) + VirtualStorageLib.getVirtualSupply();
int256 burntAmount = int256(outputValueInBase) * effectiveSupply / int256(navParams.netTotalValue);
```

Why this eliminates the trap rather than guarding it: the current form divides by
`floor(NV·10^d/ES)` — an intermediary rounded DOWN, which inflates the quotient —
while the direct form rounds once, downward, so `burnt = floor(V·ES/NV) ≤ V·ES/NV ≤
ES` by construction: the burn can never exceed the effective supply, hence at TS = 0
can never make VS negative, with no special-case gate at all. On the full return
(where the returned value IS the chain's assets, V = NV) it is exact to the unit:
`floor(V·M/V) = M` — the TS = 0 unwind lands on VS = 0 by arithmetic, not by clamp.
Verified by exhaustive property check: `floor(V·ES/NV) ≤ ES` holds for all
V ≤ NV (200k random cases), and the full-return case is exact in all of them.
Trade-offs vs the clamp: it deviates from the codebase-wide convention of pricing
every operation at `unitaryValue` (mints, burns, donations included); it needs the
ES read and an NV = 0 guard (sentinel path); and its drift direction becomes
strictly conservative (burns a sub-unit fewer shares, leaving ≤1 share of dust
positive VS instead of occasionally reverting). Session decision: pick ONE of
clamp (minimal diff, guards the symptom) or direct-ratio (removes the double-floor,
slightly wider diff) — do not ship both.

**Review checklist for the fix session (why this is a separate, careful change):**

- [ ] Clamp is gated on `totalSupply == 0` ONLY — confirm no TS > 0 path can reach
      it, and that the clamp cannot be abused to burn more VS than a chain's
      effective claims (at TS = 0 the effective supply IS the outstanding VS, so
      `burnt ≤ outstanding` keeps ES ≥ 0 by construction — prove this invariant).
- [ ] Sign safety: `burntAmount` is positive by construction (`outputValueInBase > 0`,
      `unitaryValue ≥ 1`); assert no negative-zero or overflow path.
- [ ] The clamp discards sub-unit claim value silently — confirm the discarded
      amount is bounded by the truncation error (`< u/10^d` shares) and cannot be
      amplified by repeated legs.
- [ ] Extra `getPoolTokens()` read adds an SLOAD — negligible, but confirm no
      reentrancy surface (staticcall context, no external calls between read and write).
- [ ] Check the same class of issue in every VS-writing path: `ECrosschain` arrival
      (writes +VS — cannot go negative), Escrow refund (writes +VS — same), burns
      (user-exact, cannot overshoot). Only `_handleSourceTransfer` can overshoot.
- [ ] `AIntents` is an **adapter**: shipping = new adapter + Authority governance
      update. No implementation redeploy, no `VERSION` bump, no `extensionsMapSalt`
      bump. Run `npx hardhat codesize` on the adapter and add a regression test
      pinning the TS = 0 full return (the suite already contains the trap test and
      the workaround test to derive it from).
- [ ] Consider (separately) whether `MixinPoolValue`'s zero-supply sentinel interacts
      with post-clamp dust states — the clamp targets exactly VS = 0, leaving no dust.

**Origin of the gap:** the protocol deliberately supports zero-supply chains
receiving transfers, but no test ever returned a transfer from one — the in-repo
TODO at `AIntentsRealFork.t.sol:717` records the gap, and the effective-supply DOS
guard (`NavImpactLib.validateSupply`, added Apr 2026) was never exercised against
this path.

### Remedies available today

- **New inbound Transfers are the unstick operation, and exact relief works.** An
  inbound of value `v` writes `v·10^6/u_arrival` of +VS, and `u_arrival` equals the
  pinned chain's current unitary value — readable on-chain — so the operator can
  size `v = |VS|·u/10^6` and cancel the residual **exactly**: measured one iteration,
  VS = 0 (assertEq), coverage back to par, and the **entire remaining supply then
  burns to TS = 0** with only wei-dust stranded (~$0.0000007). Verified end-to-end in
  `test_StuckToFullyBurnable_OperatorUnstick`: stuck (pin + `EffectiveSupplyTooLow`
  beyond it) → one exactly-sized inbound Transfer → 100% of supply burnable. The
  last-holder DOS is therefore **operator-remediable, not permanent** — it requires
  a specific operator action, but that action is precise, cheap, and uses the
  pool's own cross-chain assets (verified: operator personal balances untouched).
  Oversized inbounds still overshoot (positive residual strands the other way), so
  size from on-chain state rather than guessing.
- **Mints are never blocked** — in no scenario does a mint revert with negative VS
  in place (minting relaxes the `validateSupply` constraint). The only DOS surface
  is the burn tail past the pin; everything else keeps working. Burns and donations
  never relieve the pin (VS untouched).
- An **implementation upgrade** can reset the slot (governance + per-pool operator
  approval), as with any storage-affecting fix.

### Why accepted

Per-leg NAV neutrality is the design goal of the VS model, and it holds exactly. Exact
round-trip conservation would require the return leg to price against the outbound
leg's value basis — i.e. carrying cross-chain state through the bridge message and
trusting it on arrival. That couples the two chains' accounting into the message
channel and enlarges the attack surface (forged/stale bases) far beyond the bounded,
relievable residual it would eliminate. The residual is the unsettled P&L of the
bridged position during the window; the model deliberately leaves it on-chain as ±VS
instead of a message-passing liability. Same acceptance class as the existing
sync-latency and expired-refund items: real, bounded, documented.

### Operator guidance

- Cross-chain NAV parity is a periodic rebalancing target, not a maintained
  invariant — do not attempt to hold the chains at equal NAV continuously.
- Avoid initiating return legs that will straddle volatile windows when the pool's
  NAV is concentrated in repricing assets; the residual is proportional to both.
- Never perform NAV-changing actions (Sync transfers/donates, further Transfers) on
  the originating chain between initiating a Transfer and its return leg completing
  — measured to worsen the residual 2.8× at +10%. Sync _after_ the round trip does
  not repair the damage either (ratio-invariant, see above); only a new inbound
  Transfer moves coverage toward par.
- If a negative pin exists, a small inbound Transfer relieves it; monitor `VS` via
  `VirtualStorageLib.getVirtualSupply()`.

### What would change the disposition

A redesign that carries the outbound leg's value basis in the bridge message and
reconciles the return leg against it (accepting message-channel trust assumptions), or
a governance-triggered VS reset. Neither is currently planned.

Covered by `test/debug/PoCVsRoundTrip.t.sol` (18 tests: control, +10/25/50% sweeps,
burn-boundary at the pin, mint/donate liveness with negative VS, inbound-transfer
relief, sync-out coverage invariance, NAV-parity disproof, mid-window sync
worsening, realistic sync-rebalance cycle, stablecoin-pool operator-induced
residual, WETH-loss originator-pinned scenario with sync variants, stuck-to-fully-
burnable operator unstick, single-supply-chain zero-tolerance return trap,
TS=0 partial-return-plus-sync workaround, all-virtual boundary, stray-balance JIT
capture — see W22 below).

## W22 — Stray-balance capture via permissionless first-activation (accepted design consequence, Informational)

**Reported by:** deviykee (Oct 2026). **Status:** accepted design consequence of the
January 2026 zero-supply-DOS fix, severity **Informational**, no code change, no
payout. The report is **not a duplicate** of the old "externally transferred assets
are lost for the sender" wording — that wording described the pre-January-2026
behavior and is now **superseded** for allowlisted tokens by the DOS fix (see
[ZERO_SUPPLY_DOS_VULNERABILITY.md](./ZERO_SUPPLY_DOS_VULNERABILITY.md)). The only
action item is the documentation correction below.

### Behavior

When `ECrosschain.donate` activates a token that was **not previously tracked**
(`previouslyActive == false`) and the pool holds a **pre-existing balance** of that
token (externally transferred, never accounted), the first-activation validation
adds the full pre-existing balance into the expected NAV
(`ECrosschain.sol:147-153`, `tokenAmount += storedBalance`), but **no offsetting
virtual supply is written for it** — Sync mode writes no VS at all
(`ECrosschain.sol:97-102`), and even Transfer mode writes VS only for the
bridge-expected `amount`, not for `storedBalance` (`ECrosschain.sol:97-99`).

The result: unitary value jumps by `strayValue / effectiveSupply` at activation.
A JIT minter who minted base while the stray was still invisible to NAV holds
shares priced at the old unitary value and can burn them after `minPeriod` into
the newly activated token, capturing the stray. `NavDecreased` (the interleaving
guard, `ECrosschain.sol:171`) does not block this — it only blocks unitary-value
_decreases_, and the activation is an increase.

`donate` is permissionless **by design** (`ECrosschain.sol:23` — "anyone with
tokens to donate"), so no privilege is needed. The donate transient lock requires
the two-step sequence (`donate(token, 1, Sync)` snapshot → transfer delta →
`donate(token, delta, Sync)`) to execute **atomically in one transaction**.

### Why this is not a vulnerability

1. **The captured value is a balance the protocol already treats as lost or
   donated.** Before the January 2026 zero-supply-DOS fix, a donation activating a
   pre-funded token **reverted** (`NavManipulationDetected`), so stray allowlisted
   balances could never enter NAV via `donate`. The DOS fix deliberately changed
   this so legitimate Across fills to pre-funded pools succeed. The side effect —
   stray value entering NAV with no offsetting VS — is the **intended price of that
   fix**, not an unintended bug. Capturing it is capturing a donation, not stealing
   accounted user deposits.

2. **No accounted principal is at risk.** The control test (`WETH accounted via
`mintWithToken`` before activation) shows the attacker captures **zero** — the
   entry path that issues shares against the real asset value is unaffected.

3. **If the attacker is the only holder and the stray sender, there is no external
   damage.** He is recovering his own externally transferred balance (minus the
   `minPeriod` lock and spread). If there are existing LPs, the attacker captures a
   share of the stray that would otherwise have uplifted all LPs on organic
   activation — a redistribution of the donation, not a loss of principal.

4. **The capital is locked for `minPeriod`** (default 30 days) and the profit is
   bounded to the stray balance of an allowlisted token on a pool that has not yet
   activated it. The attack fires once per stray balance per pool.

### Measured behavior (fork test `test_StrayBalance_JitCapture_ViaSyncActivate`)

- **Empty pool, 50 WETH stray:** user mints ~1 ETH of base while the stray is
  invisible (`u == 1e6`, asserted); one-tx donate sequence activates WETH;
  `u` jumps to ~51,050,050 (50× supply, asserted); after `minPeriod` the user
  burns and captures **~49.95 of 50 WETH** (asserted > 45 WETH).
- **Existing 1 ETH LP + user mints 1 ETH + 20 WETH stray:** user captures
  **~50% of the stray** — exactly his share of supply; the existing LP's
  principal is untouched (share count asserted unchanged) and his claim also rises.
- **Control (WETH accounted via `mintWithToken` before activation):** user
  captures **0** WETH (asserted) — accounted principal is not affected.

These numbers confirm the mechanism but do not change the severity: the captured
value is a balance already treated as lost/donated.

### Candidate design changes (not scheduled)

The following options were considered and rejected for the current train because
the current behavior is accepted:

1. **NAV-neutral activation:** on first activation, write `+VS` for the
   pre-existing balance's share value in **both** modes. This would prevent the
   unitary-value jump and the JIT capture, but it strands the value as positive
   VS — a different accepted residual class. Only relevant if the protocol later
   decides to treat stray balances as communal surplus rather than capturable
   donations.
2. **Restore "stay lost" semantics for the pre-existing balance:** count only
   `amountDelta` toward expected NAV for inactive tokens. This reintroduces the
   pre-funded-token DOS the January 2026 fix removed — rejected.
3. **Restrict `donate` caller:** rejected — `donate` is deliberately
   permissionless, and caller restriction does not prevent the same effect on
   the operator's or Across's own legitimate activation anyway.

### Disposition

Accepted design consequence, **Informational**, no bounty. Documentation updated
to replace the outdated "lost for the sender" wording for allowlisted tokens.
No contract change is required. The behavior is bounded to pre-existing balances
of allowlisted tokens and is the intended result of the zero-supply-DOS fix.

## W23 — Sentinel unitary value during non-positive NAV (accepted limitation, Informational)

**Reported by:** anonymous (Oct 2026). **Status:** accepted limitation, severity
**Informational**, no code change, no payout. The behavior is a deliberate
sentinel design choice; the three division paths are only reachable when the pool
is already in a non-positive NAV state (effectively insolvent).

### Shared root

`MixinPoolValue.sol:70-77` stores `unitaryValue = 1` whenever `netTotalValue` is
not greater than `0` while effective supply is outstanding. This is intentional
**burn-side protection**: it prevents holders from draining the pool at a stale
or zero unitary value during an insolvency event. The same block also clamps a
dust-positive unitary value back to `1` (`MixinPoolValue.sol:80-84`).

A non-positive NAV episode can in principle arise from an underwater Hyperliquid
perp position: `HyperliquidLib.sol:32-56` casts the signed precompile
`accountValue` into the NAV sum unclamped, so if the perp loss exceeds the spot
cash offset, `netTotalValue` becomes non-positive. No owner action is required
beyond the market mark moving.

### Three affected paths

While the sentinel is stored, any operation that divides a value by
`unitaryValue` (or by the transient `storedNav`) scales the result by
`10^decimals` instead of by the fair share fraction:

1. **Mint (`MixinActions.sol:175`).** `mintedAmount = amountIn * 10^decimals /
unitaryValue`. At sentinel `1` the minter receives `amountIn * 10^decimals`
   shares. If the NAV later recovers, the minter burns those shares and captures
   value from the pre-existing holders.
2. **Across source debit (`AIntents.sol:253`).** `burntAmount = outputValueInBase
   - 10^decimals / unitaryValue`. A routine outbound Transfer writes a negative
virtual supply of `outputValue * 10^decimals`, which can pin effective supply
at the `validateSupply` floor (`NavImpactLib`) and lock the burn tail.
3. **Destination credit (`ECrosschain.sol:128`).** `mintedAmount =
amountValueInBase * 10^decimals / storedNav`. An inbound fill writes a phantom
   positive virtual supply of `amount * 10^decimals`, deflating the unitary value
   when the mark later recovers.

The researcher provided local Foundry PoCs confirming all three effects at the
pinned commit.

### Why this is not a rewardable finding

- **The precondition is insolvency, not a normal operating state.** A pool with
  `netTotalValue <= 0` has no positive net asset value per share. The sentinel is
  the protocol's chosen behavior for that state. Operations that price against it
  are only corrupt in the same sense that arithmetic on an insolvent balance sheet
  is ill-defined.
- **No deployed pool is currently affected.** The researcher checked all 12
  registered Arbitrum pools and found none with `unitaryValue == 1` and supply
  outstanding.
- **The Hyperliquid path is a black-swan liquidation failure.** Reaching
  `accountValue < 0` requires the perp position to be underwater beyond the spot
  cash offset after Hyperliquid's auto-liquidation mechanism has run. This is not
  a routine market move.
- **No current user funds are at risk, and no immediate exploit exists.** The
  mint attack additionally requires the attacker to mint _during_ the sentinel
  window and for the NAV to recover afterwards — a recovery-from-insolvency
  scenario, not a present exploit.

### Disposition

Accepted limitation, **Informational**, no bounty. No contract change is
required. The external Known Issues wording should reflect that the sentinel is
an insolvency handler and that pricing operations during `unitaryValue == 1` are
not guaranteed to be fair. If the protocol later wants to harden this surface, a
cheap guard is to revert (or skip the VS/share write) in mint, source-debit, and
destination-credit paths when `unitaryValue == 1` or `netTotalValue <= 0`.

### Possible future hardening (not scheduled)

- **Mint:** revert if `unitaryValue == 1` or `netTotalValue <= 0` before issuing
  shares; or price against the last positive stored unitary value.
- **Source debit:** revert the Transfer initiation if the chain is at sentinel,
  preventing a `10^decimals`-scaled negative VS write.
- **Destination credit:** skip the VS write or price it against the last positive
  stored unitary value while at sentinel.

Any such change must preserve the burn-side sentinel behavior, because that is
what protects remaining holders from being drained at stale NAV during
insolvency.
