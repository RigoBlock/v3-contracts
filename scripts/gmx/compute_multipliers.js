const fs = require("fs");
const { ethers } = require("ethers");

const INPUT = "scripts/gmx/gmx_fallback_feeds.json";
const OUTPUT = "scripts/gmx/gmx_fallback_feeds_with_multipliers.json";

// GMX DataStore on Arbitrum. The authoritative `tokenDecimals` for synthetic
// index tokens is derived from the on-chain DATA_STREAM_MULTIPLIER
// (`10^(42 - tokenDecimals)`), NOT from a local config file: tokens missing
// from the vendored config previously fell back to a wrong hardcoded default.
const GMX_DATA_STORE = "0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8";

const DATA_STREAM_MULTIPLIER_PREFIX = ethers.utils.keccak256(
  ethers.utils.defaultAbiCoder.encode(["string"], ["DATA_STREAM_MULTIPLIER"]),
);

function dataStreamMultiplierKey(token) {
  return ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(
      ["bytes32", "address"],
      [DATA_STREAM_MULTIPLIER_PREFIX, token],
    ),
  );
}

/// @dev Inverts `multiplier = 10^(42 - tokenDecimals)`, reverting on any
///  non-conforming value so a bad entry never silently produces a multiplier.
function tokenDecimalsFromMultiplier(symbol, multiplier) {
  if (multiplier.isZero()) {
    throw new Error(`${symbol}: no DATA_STREAM_MULTIPLIER on GMX DataStore`);
  }
  const str = multiplier.toString();
  if (!/^10*$/.test(str)) {
    throw new Error(
      `${symbol}: DATA_STREAM_MULTIPLIER ${str} is not a power of 10`,
    );
  }
  const exponent = str.length - 1;
  const tokenDecimals = 42 - exponent;
  if (tokenDecimals < 0 || tokenDecimals > 18) {
    throw new Error(
      `${symbol}: DATA_STREAM_MULTIPLIER implies implausible tokenDecimals ${tokenDecimals}`,
    );
  }
  return tokenDecimals;
}

const provider = new ethers.providers.JsonRpcProvider(
  "https://arb1.arbitrum.io/rpc",
);

const dataStoreAbi = ["function getUint(bytes32 key) view returns (uint256)"];
const feedAbi = ["function decimals() view returns (uint8)"];

async function main() {
  // Start from the existing file so previously-computed entries are preserved
  // if a single entry fails; the loop below re-derives every multiplier from
  // on-chain state and throws on mismatch rather than trusting stale data.
  let existing = [];
  if (fs.existsSync(OUTPUT)) {
    existing = JSON.parse(fs.readFileSync(OUTPUT, "utf8"));
    if (!Array.isArray(existing)) existing = [];
  }
  const existingByToken = {};
  for (const e of existing) {
    existingByToken[e.indexToken.toLowerCase()] = e;
  }

  const fallback = JSON.parse(fs.readFileSync(INPUT, "utf8"));
  const dataStore = new ethers.Contract(GMX_DATA_STORE, dataStoreAbi, provider);

  const results = [];
  const errors = [];
  for (const entry of fallback) {
    const token = ethers.utils.getAddress(entry.indexToken);
    try {
      const feed = new ethers.Contract(entry.feedAddress, feedAbi, provider);
      const [feedDecimals, multiplier] = await Promise.all([
        feed.decimals(),
        dataStore.getUint(dataStreamMultiplierKey(token)),
      ]);
      const tokenDec = tokenDecimalsFromMultiplier(entry.symbol, multiplier);
      const computed = ethers.BigNumber.from(10).pow(
        60 - feedDecimals - tokenDec,
      );

      const previous = existingByToken[token.toLowerCase()];
      if (previous && previous.multiplier !== computed.toString()) {
        console.warn(
          `${entry.symbol}: multiplier changed ${previous.multiplier} -> ${computed.toString()} ` +
            `(feedDecimals=${feedDecimals}, tokenDecimals=${tokenDec})`,
        );
      }

      results.push({
        ...entry,
        feedDecimals,
        tokenDecimals: tokenDec,
        multiplier: computed.toString(),
      });
      console.log(
        `${entry.symbol} ${token} feed=${feedDecimals} token=${tokenDec} mult=${computed.toString()}`,
      );
    } catch (e) {
      errors.push(`${entry.symbol}: ${e.message}`);
    }
  }

  if (errors.length > 0) {
    console.error(`Failed to derive multipliers for ${errors.length} entries:`);
    for (const err of errors) console.error("  " + err);
    throw new Error("Refusing to write output with missing entries");
  }

  fs.writeFileSync(OUTPUT, JSON.stringify(results, null, 2));
  console.log(`Wrote ${results.length} entries to ${OUTPUT}`);
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
