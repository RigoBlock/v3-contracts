# GMX fallback feed maintenance scripts

This folder contains helper scripts for maintaining the hardcoded Chainlink
fallback feeds used by `GmxFallback.getFallbackPriceFeed()` for GMX
synthetic index tokens that have a Data Stream feed but no on-chain `priceFeed`.

## Workflow

1. **Discover missing feeds**

   ```bash
   node scripts/gmx/discover_gmx_missing_feeds.js
   ```

   Scans all live GMX markets on Arbitrum and writes
   `scripts/gmx/gmx_missing_feeds.json` with index tokens that cannot be priced
   by the GMX Chainlink provider.

2. **Match them to Chainlink USD aggregators**

   ```bash
   node scripts/gmx/find_fallback_feeds.js <markets-config-file> <feeds-json-file>
   ```

   - `markets-config-file`: local copy of the GMX markets config
     (`lib/gmx-synthetics/config/markets.ts`).
   - `feeds-json-file`: local Chainlink feeds list for Arbitrum
     (`scripts/gmx/feeds-arbitrum-mainnet.json`).

   Produces `scripts/gmx/gmx_fallback_feeds.json`.

   **Merging:** if `gmx_fallback_feeds.json` already exists, newly discovered
   entries are merged in and any previously-mapped entry that is still missing
   a GMX price feed is preserved. This prevents accidental data loss when a
   token is temporarily discoverable through a different path or when you add
   manual mappings.

3. **Compute GMX multipliers**

   ```bash
   node scripts/gmx/compute_multipliers.js
   ```

   Reads `gmx_fallback_feeds.json` and, for each entry, queries on Arbitrum:
   the Chainlink aggregator's `decimals()`, and GMX's on-chain
   `DATA_STREAM_MULTIPLIER` (`10^(42 - tokenDecimals)`) from the GMX
   DataStore. Token decimals are **always derived from GMX's on-chain
   config** — the script throws and refuses to write output if a token has
   no multiplier or a non-power-of-10 multiplier, so the exponent
   `60 - feedDecimals - tokenDecimals` can never silently fall back to a
   wrong default. Writes `scripts/gmx/gmx_fallback_feeds_with_multipliers.json`.

4. **Generate Solidity**

   ```bash
   node scripts/gmx/generate_gmx_fallback_solidity.js
   ```

   Patches `contracts/protocol/types/GmxFallback.sol` in-place (replacing
   only the body between `// GMX_FALLBACK_LOOKUP_START` and
   `// GMX_FALLBACK_LOOKUP_END` with a packed, batched lookup),
   regenerates `test/libraries/GmxFallback.t.sol`, and rewrites the marked
   section (`// GMX_FALLBACK_FORK_TESTS_START` /
   `// GMX_FALLBACK_FORK_TESTS_END`) inside `test/extensions/AGmxV2Fork.t.sol`,
   leaving the rest of that file untouched. Each entry is encoded as
   `uint168(feedAddress << 8 | exponent)`, where `multiplier = 10 ** exponent`.

   The generator emits raw formatting — always run Prettier afterwards,
   otherwise the committed files drift on every regeneration:

   ```bash
   npx prettier --write contracts/protocol/types/GmxFallback.sol \
     test/libraries/GmxFallback.t.sol test/extensions/AGmxV2Fork.t.sol
   ```

   Use `--stdout` to print the generated block instead of patching the file:

   ```bash
   node scripts/gmx/generate_gmx_fallback_solidity.js --stdout
   ```

5. **Verify contract sizes**

   Production deployments use 200 optimizer runs. Always check sizes with:

   ```bash
   FOUNDRY_OPTIMIZER_RUNS=200 forge build --sizes
   ```

   The default Foundry profile (`optimizer_runs = 1_000_000` in `foundry.toml`)
   reports smaller contracts, so it is misleading for deployability checks.

## Notes

- The lookup is a **batched address-nibble grouping**. Entries are split by the
  first hex digit of the token address (`uint160(token) >> 156`) and then
  compared directly inside each bucket. This is gas-efficient and compact enough
  to deploy at 200 optimizer runs.
- `getFallbackPriceFeed` returns a packed `Feed` (`uint168`);
  callers decode it as `address(feed) << 8 | exponent`, where `multiplier = 10 ** exponent`.
  The token address is the caller's input, so it is not copied back out.
- `test/libraries/GmxFallback.t.sol` is regenerated alongside the contract and
  asserts that every mapped token returns the correct feed address and exponent,
  while unmapped tokens return the zero feed address. The expected exponent is
  computed in the test as `60 - feedDecimals - tokenDecimals` to catch rogue
  multipliers produced by the script.
- The generated fork-test section inside `test/extensions/AGmxV2Fork.t.sol`
  (single suite `AGmxV2ForkTest`) verifies on an Arbitrum fork that each
  packed exponent matches GMX's own on-chain config: the Chainlink
  aggregator `decimals()` and the DataStore `DATA_STREAM_MULTIPLIER` (from
  which token decimals are derived as `42 - log10(multiplier)`). It also
  asserts end-to-end that the price returned by `getFallbackPrice` equals
  the live aggregator answer scaled by the derived multiplier, and that
  every mapped feed is fresh (within the 24h `_FALLBACK_HEARTBEAT`). This
  is the guard against a wrong multiplier ever reaching the contract again.
- **Pinned fork block.** The fork test uses `Constants.ARB_BLOCK`
  (`contracts/test/ForkBlocks.sol`), not the latest block: CI caches fork
  state keyed by the `ForkBlocks.sol` hash, so chain data is populated once
  when the block is bumped, not on every run. Bump the block deliberately and
  re-run the Arbitrum fork suites (`AGmxV2ForkTest` in
  `test/extensions/AGmxV2Fork.t.sol`, `GmxLitPoolFork`, `AUniswapRouterFork`,
  `NavViewStressedParityFork`). The test fails loudly, with a "bump
  `ForkBlocks.ARB_BLOCK`" hint, when a mapped token's feed or GMX multiplier
  did not exist at the pinned block — i.e. the token was listed after it.
  Regular block bumps also clear dead mappings: the freshness assertion fails
  at the new block for any feed that has gone stale (market delisted /
  Chainlink paused), prompting removal of the dead entry.
- The function lives in `contracts/protocol/types/GmxFallback.sol`
  and is imported by both `GmxLib` (NAV calculations) and `GmxAdapterLib`
  (adapter order validation), so the fallback data is shared without forcing
  adapter-only helpers into the NAV code path.
- When the list grows, the generate script re-balances the buckets automatically.
  Adding many new tokens may eventually require moving the registry to an
  external module; the current design is intended to fit the release set.
- **Bug bounty scope.** The mapping is generated and verified against chain state at
  the pinned `Constants.ARB_BLOCK`. Mapping changes that result solely from bumping the
  pinned block (stale Chainlink Data Streams, GMX deprecating synthetic tokens) are
  informative maintenance and out of scope of the bug bounty program; wrong
  multipliers/feeds relative to on-chain GMX config at the pinned block are in scope.
