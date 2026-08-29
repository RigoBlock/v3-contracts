# GMX fallback feed maintenance scripts

This folder contains helper scripts for maintaining the hardcoded Chainlink
fallback feeds used by `GmxLib._fallbackFeeds()` for GMX synthetic index
tokens that have a Data Stream feed but no on-chain `priceFeed`.

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

   Patches `contracts/protocol/libraries/GmxLib.sol` in-place, replacing only
   the `_fallbackFeeds()` body with the sorted `FallbackPriceFeedData[N]` array.
   The binary-search helper and fallback price logic in `GmxLib.sol` are left
   untouched.

   Use `--stdout` to print the generated block instead of patching the file:

   ```bash
   node scripts/gmx/generate_gmx_fallback_solidity.js --stdout
   ```

## Notes

- The production code uses a **binary search over a memory array**. A batched
  address-interval lookup is ~10× cheaper in runtime gas (measured: binary
  search ~2.9–4.5 k gas, batched lookup ~0.27–0.48 k gas for the 27-entry list)
  but increases the bytecode of `EApps`/`ENavView` enough to push it over the
  contract-size limit, so binary search is the practical choice.
- `_getFallbackPriceFeed` returns only `(address feed, uint256 multiplier)`;
  the token address is the caller's input, so it is not copied back out.
- When the list grows, the generate script automatically emits the new array
  size (`FallbackPriceFeedData[N]`). The binary-search helper itself stays the
  same because it reads `feeds.length`.
