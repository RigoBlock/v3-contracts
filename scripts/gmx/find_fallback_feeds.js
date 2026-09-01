const fs = require("fs");
const { ethers } = require("ethers");

const OUTPUT = "scripts/gmx/gmx_fallback_feeds.json";

const missing = JSON.parse(
  fs.readFileSync("scripts/gmx/gmx_missing_feeds.json", "utf8"),
).missing;
const missingSet = new Set(missing.map((a) => a.toLowerCase()));

// Usage: node scripts/gmx/find_fallback_feeds.js <markets-config-file> <feeds-json-file>
// markets-config-file: local copy of GMX markets config (e.g., lib/gmx-synthetics/config/markets.ts)
// feeds-json-file: local Chainlink feeds list (e.g., scripts/gmx/feeds-arbitrum-mainnet.json)
const marketsFile = process.argv[2] || "lib/gmx-synthetics/config/markets.ts";
const feedsFile = process.argv[3] || "scripts/gmx/feeds-arbitrum-mainnet.json";

const marketsText = fs.readFileSync(marketsFile, "utf8");

// Extract Arbitrum market entries: comment + object
const arbitrumBlock = marketsText
  .split("[ARBITRUM]")[1]
  .split("[ARBITRUM_SEPOLIA]")[0];

const marketRegex =
  /\/\/\s*([^\n]+?)\s*\n\s*"(0x[a-fA-F0-9]{40})":\s*\{\s*marketTokenAddress:\s*"(0x[a-fA-F0-9]{40})",\s*indexTokenAddress:\s*"(0x[a-fA-F0-9]{40})",/g;
let match;
const indexToSymbol = {};
while ((match = marketRegex.exec(arbitrumBlock)) !== null) {
  const comment = match[1].trim();
  const market = match[2];
  const indexToken = match[4];
  // Extract base symbol from comment, e.g. "BTC/USD [WBTC.e-USDC]" -> "BTC"
  const symbolMatch = comment.match(/^([A-Za-z0-9._]+)\/USD/);
  const symbol = symbolMatch ? symbolMatch[1] : null;
  if (symbol && missingSet.has(indexToken.toLowerCase())) {
    indexToSymbol[indexToken.toLowerCase()] = { symbol, market, comment };
  }
}

console.log(
  `Mapped ${Object.keys(indexToSymbol).length} missing tokens to symbols`,
);

const feeds = JSON.parse(fs.readFileSync(feedsFile, "utf8"));

// Merge with any previously-discovered or manually-added entries so we never
// accidentally drop a mapping when GMX temporarily reports a price or the
// discovery run is partial.
let existing = [];
if (fs.existsSync(OUTPUT)) {
  existing = JSON.parse(fs.readFileSync(OUTPUT, "utf8"));
  if (!Array.isArray(existing)) existing = [];
}
const merged = {};
for (const e of existing) {
  const key = e.indexToken.toLowerCase();
  merged[key] = e;
}

const results = [];
for (const [indexToken, info] of Object.entries(indexToSymbol)) {
  const symbol = info.symbol;
  // Find a USD feed for this symbol
  const base = symbol.replace(/\.e$/, "");
  const nameRegex = new RegExp(
    `^${base.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*/\\s*USD`,
  );
  const feed = feeds.find(
    (f) =>
      f.proxyAddress && f.contractType !== "verifier" && nameRegex.test(f.name),
  );

  if (feed) {
    const key = indexToken.toLowerCase();
    const discovered = {
      indexToken: ethers.utils.getAddress(indexToken),
      symbol,
      market: info.market,
      feedAddress: feed.proxyAddress,
      feedName: feed.name,
      decimals: feed.decimals || 8,
    };
    const previous = merged[key];
    if (!previous) {
      console.log(
        `NEW  ${symbol} ${discovered.indexToken} -> ${feed.proxyAddress}`,
      );
    } else if (
      previous.feedAddress.toLowerCase() !== feed.proxyAddress.toLowerCase()
    ) {
      console.log(
        `UPD  ${symbol} ${discovered.indexToken} -> ${feed.proxyAddress}`,
      );
    }
    merged[key] = discovered;
  } else {
    console.log(`No Chainlink USD feed for ${symbol} (${info.comment})`);
  }
}

for (const e of Object.values(merged)) {
  results.push(e);
}

fs.writeFileSync(OUTPUT, JSON.stringify(results, null, 2));
console.log(`Wrote ${results.length} fallback feeds to ${OUTPUT}`);
for (const r of results) {
  console.log(`${r.symbol} ${r.indexToken} -> ${r.feedAddress}`);
}
