const fs = require("fs");
const { ethers } = require("ethers");

const INPUT = "scripts/gmx/gmx_fallback_feeds.json";
const OUTPUT = "scripts/gmx/gmx_fallback_feeds_with_multipliers.json";

const fallback = JSON.parse(fs.readFileSync(INPUT, "utf8"));
const configText = fs.readFileSync(
  "lib/gmx-synthetics/config/tokens.ts",
  "utf8",
);

const arbitrumConfig = configText.split("arbitrum:")[1].split("avax:")[0];
const tokenRegex = /([A-Z][A-Z0-9._]*):\s*\{([\s\S]*?)\n\s*\},?/g;

const tokenDecimals = {};
let match;
while ((match = tokenRegex.exec(arbitrumConfig)) !== null) {
  const symbol = match[1];
  const body = match[2];
  const decMatch = body.match(/decimals:\s*(\d+)/);
  if (decMatch) {
    tokenDecimals[symbol] = parseInt(decMatch[1]);
  }
}

const provider = new ethers.providers.JsonRpcProvider(
  "https://arb1.arbitrum.io/rpc",
);
const feedAbi = [
  "function decimals() view returns (uint8)",
  "function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)",
];

async function main() {
  // Start from the existing file so manual overrides or previously-computed
  // entries are preserved even if the current RPC call fails.
  let existing = [];
  if (fs.existsSync(OUTPUT)) {
    existing = JSON.parse(fs.readFileSync(OUTPUT, "utf8"));
    if (!Array.isArray(existing)) existing = [];
  }
  const existingByToken = {};
  for (const e of existing) {
    existingByToken[e.indexToken.toLowerCase()] = e;
  }

  const results = [];
  for (const entry of fallback) {
    const key = entry.indexToken.toLowerCase();
    try {
      const feed = new ethers.Contract(entry.feedAddress, feedAbi, provider);
      const feedDecimals = await feed.decimals();
      const tokenDec = tokenDecimals[entry.symbol] || 18;
      const multiplier = ethers.BigNumber.from(10).pow(
        60 - feedDecimals - tokenDec,
      );

      results.push({
        ...entry,
        feedDecimals,
        tokenDecimals: tokenDec,
        multiplier: multiplier.toString(),
      });
      console.log(
        `${entry.symbol} ${entry.indexToken} feed=${feedDecimals} token=${tokenDec} mult=${multiplier.toString()}`,
      );
    } catch (e) {
      const previous = existingByToken[key];
      if (previous) {
        console.warn(
          `RPC failed for ${entry.symbol}; preserving existing multiplier (${previous.multiplier})`,
        );
        results.push(previous);
      } else {
        console.error(`Error ${entry.symbol}:`, e.message);
      }
    }
  }

  fs.writeFileSync(OUTPUT, JSON.stringify(results, null, 2));
  console.log(`Wrote ${results.length} entries to ${OUTPUT}`);
}

main().catch(console.error);
