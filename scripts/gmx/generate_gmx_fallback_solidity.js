const fs = require("fs");
const { ethers } = require("ethers");

const INPUT = "scripts/gmx/gmx_fallback_feeds_with_multipliers.json";
const CONTRACT = "contracts/protocol/libraries/GmxLib.sol";

const GROUP_SIZE = 6;

const fallback = JSON.parse(fs.readFileSync(INPUT, "utf8"));

// Sort by checksummed token address using numeric order, required by the batched lookup.
const sorted = fallback
  .map((e) => ({ ...e, token: ethers.utils.getAddress(e.indexToken) }))
  .sort((a, b) => {
    const aBig = BigInt.asUintN(160, BigInt(a.token));
    const bBig = BigInt.asUintN(160, BigInt(b.token));
    return aBig < bBig ? -1 : aBig > bBig ? 1 : 0;
  });

function buildGroups() {
  const groups = [];
  for (let i = 0; i < sorted.length; i += GROUP_SIZE) {
    const slice = sorted.slice(i, i + GROUP_SIZE);
    groups.push({
      max: slice[slice.length - 1].token,
      entries: slice,
      isLast: i + GROUP_SIZE >= sorted.length,
    });
  }
  return groups;
}

function emitEntry(e) {
  return `        if (token == ${e.token}) return (${e.feedAddress}, ${e.multiplier});`;
}

function buildFunction() {
  const groups = buildGroups();
  const lines = [
    "    /// @dev Hardcoded Chainlink fallback feeds for GMX synthetic index tokens.",
    "    ///  The multiplier converts the aggregator answer (feedDecimals) to GMX's 1e30",
    "    ///  token-unit price. Returns `(address(0), 0)` for unmapped tokens.",
    "    function _getFallbackPriceFeed(address token) private pure returns (address feed, uint256 multiplier) {",
  ];

  for (const g of groups) {
    if (!g.isLast) {
      lines.push(`        if (token <= ${g.max}) {`);
      for (const e of g.entries) {
        lines.push(`            ${emitEntry(e).trimStart()}`);
      }
      lines.push("            return (address(0), 0);");
      lines.push("        }");
    } else {
      for (const e of g.entries) {
        lines.push(emitEntry(e));
      }
    }
  }

  lines.push("        return (address(0), 0);");
  lines.push("    }");
  return lines.join("\n");
}

function patchContract() {
  const sol = fs.readFileSync(CONTRACT, "utf8");
  const startMarker = "    // GMX_FALLBACK_LOOKUP_START";
  const endMarker = "    // GMX_FALLBACK_LOOKUP_END";

  const startIdx = sol.indexOf(startMarker);
  const endIdx = sol.indexOf(endMarker);
  if (startIdx === -1 || endIdx === -1 || endIdx <= startIdx) {
    throw new Error(
      `Could not find fallback markers in ${CONTRACT}. ` +
        `Expected '${startMarker}' and '${endMarker}'.`,
    );
  }

  const before = sol.slice(0, startIdx);
  const after = sol.slice(endIdx + endMarker.length);
  const replacement = buildFunction();

  fs.writeFileSync(CONTRACT, before + replacement + after, "utf8");
  console.log(
    `Patched ${CONTRACT} with ${sorted.length} fallback entries (${new Date().toISOString()})`,
  );
}

function printToStdout() {
  console.log(
    "// Sorted fallback price feeds for GMX index tokens without a GMX priceFeed",
  );
  console.log("// Source: Chainlink on-chain aggregators on Arbitrum");
  console.log("// Generated on", new Date().toISOString());
  console.log("");
  console.log(buildFunction());
}

if (process.argv.includes("--stdout")) {
  printToStdout();
} else {
  patchContract();
}
