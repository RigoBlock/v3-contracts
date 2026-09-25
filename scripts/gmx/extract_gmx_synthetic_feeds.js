const fs = require("fs");
const { ethers } = require("ethers");

function hashData(dataTypes, dataValues) {
  const bytes = ethers.utils.defaultAbiCoder.encode(dataTypes, dataValues);
  return ethers.utils.keccak256(ethers.utils.arrayify(bytes));
}

function getSyntheticTokenAddress(chainId, tokenSymbol) {
  const hash = hashData(["uint256", "string"], [chainId, tokenSymbol]);
  return ethers.utils.getAddress("0x" + hash.slice(-40));
}

const configText = fs.readFileSync(
  "lib/gmx-synthetics/config/tokens.ts",
  "utf8",
);
const missing = JSON.parse(
  fs.readFileSync("scripts/gmx/gmx_missing_feeds.json", "utf8"),
).missing;
const missingSet = new Set(missing.map((a) => a.toLowerCase()));

const arbitrumConfig = configText.split("arbitrum:")[1].split("avax:")[0];

// Extract all token blocks: SYMBOL: { ... }
const tokenRegex = /([A-Z][A-Z0-9._]*):\s*\{([\s\S]*?)\n\s*\},?/g;
let match;
const results = [];

while ((match = tokenRegex.exec(arbitrumConfig)) !== null) {
  const symbol = match[1];
  const body = match[2];

  if (!body.includes("synthetic:") && !body.includes("address:")) continue;

  // Get decimals
  const decimalsMatch = body.match(/decimals:\s*(\d+)/);
  const decimals = decimalsMatch ? parseInt(decimalsMatch[1]) : 18;

  // Get priceFeed address
  const priceFeedMatch = body.match(
    /priceFeed:\s*\{\s*address:\s*"(0x[a-fA-F0-9]{40})"/,
  );
  const priceFeed = priceFeedMatch ? priceFeedMatch[1] : null;

  // Get dataStreamFeedId
  const dataStreamMatch = body.match(
    /dataStreamFeedId:\s*"(0x[a-fA-F0-9]{64})"/,
  );
  const dataStreamId = dataStreamMatch ? dataStreamMatch[1] : null;

  if (!priceFeed) continue;

  const address = getSyntheticTokenAddress(42161, symbol);
  if (missingSet.has(address.toLowerCase())) {
    results.push({ symbol, address, decimals, priceFeed, dataStreamId });
  }
}

fs.writeFileSync(
  "scripts/gmx/gmx_synthetic_feeds.json",
  JSON.stringify(results, null, 2),
);
console.log(
  `Found ${results.length} synthetic tokens with price feeds matching missing list`,
);
for (const r of results) {
  console.log(`${r.symbol} ${r.address} -> ${r.priceFeed}`);
}
