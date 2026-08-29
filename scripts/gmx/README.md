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

   Reads `gmx_fallback_feeds.json`, queries each aggregator's decimals, and
   writes `scripts/gmx/gmx_fallback_feeds_with_multipliers.json`.

   **Merging:** existing entries whose on-chain query fails are preserved with
   their previous multiplier, so a flaky RPC call does not wipe manually-corrected
   values.

4. **Generate Solidity**

   ```bash
   node scripts/gmx/generate_gmx_fallback_solidity.js
   ```

   Patches `contracts/protocol/types/GmxFallback.sol` in-place,
   replacing only the body between `// GMX_FALLBACK_LOOKUP_START` and
   `// GMX_FALLBACK_LOOKUP_END` with a packed, batched lookup. Each entry is
   encoded as `bytes32(feedAddress << 96 | exponent)`, where
   `multiplier = 10 ** exponent`.

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
- `getFallbackPriceFeed` returns a packed `Feed` (`bytes32`);
  callers decode it as `address(feed) << 96 | exponent`, where `multiplier = 10 ** exponent`.
  The token address is the caller's input, so it is not copied back out.
- The function lives in `contracts/protocol/types/GmxFallback.sol`
  and is imported by both `GmxLib` (NAV calculations) and `GmxAdapterLib`
  (adapter order validation), so the fallback data is shared without forcing
  adapter-only helpers into the NAV code path.
- When the list grows, the generate script re-balances the buckets automatically.
  Adding many new tokens may eventually require moving the registry to an
  external module; the current design is intended to fit the release set.
