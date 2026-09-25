const fs = require("fs");

const configText = fs.readFileSync(
  "lib/gmx-synthetics/config/tokens.ts",
  "utf8",
);
const missing = JSON.parse(
  fs.readFileSync("scripts/gmx/gmx_missing_feeds.json", "utf8"),
).missing;

// Find each token address and its priceFeed address in the config
const matches = [];
for (const token of missing) {
  const tokenLower = token.toLowerCase();
  // Find the token in the config
  const idx = configText.toLowerCase().indexOf(tokenLower);
  if (idx === -1) {
    console.log(`NOT FOUND in config: ${token}`);
    continue;
  }

  // Extract a chunk around the token
  const start = Math.max(0, idx - 200);
  const end = Math.min(configText.length, idx + 500);
  const chunk = configText.slice(start, end);

  // Try to find priceFeed: { address: "..." }
  const feedMatch = chunk.match(
    /priceFeed:\s*\{\s*address:\s*"(0x[a-fA-F0-9]{40})"/,
  );
  const symbolMatch = chunk.match(/([A-Z][A-Z0-9._]*):\s*\{/);

  if (feedMatch) {
    matches.push({
      token,
      symbol: symbolMatch ? symbolMatch[1] : "?",
      feed: feedMatch[1],
    });
  } else {
    console.log(
      `No priceFeed in config for ${token} ${symbolMatch ? symbolMatch[1] : ""}`,
    );
  }
}

fs.writeFileSync(
  "scripts/gmx/gmx_matched_feeds.json",
  JSON.stringify(matches, null, 2),
);
console.log(`Matched ${matches.length} tokens with price feeds`);
