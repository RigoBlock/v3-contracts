const fs = require("fs");
const { ethers } = require("ethers");

const INPUT = "scripts/gmx/gmx_fallback_feeds_with_multipliers.json";
const CONTRACT = "contracts/protocol/types/GmxFallback.sol";

const fallback = JSON.parse(fs.readFileSync(INPUT, "utf8"));

// Sort by checksummed token address using numeric order, required by the batched lookup.
const sorted = fallback
  .map((e) => ({ ...e, token: ethers.utils.getAddress(e.indexToken) }))
  .sort((a, b) => {
    const aBig = BigInt.asUintN(160, BigInt(a.token));
    const bBig = BigInt.asUintN(160, BigInt(b.token));
    return aBig < bBig ? -1 : aBig > bBig ? 1 : 0;
  });

function computeExponent(multiplier) {
  const str = multiplier.toString();
  if (!/^10*$/.test(str)) {
    throw new Error(`Multiplier ${multiplier} is not a power of 10`);
  }
  return str.length - 1;
}

function packEntry(e) {
  const exponent = computeExponent(e.multiplier);
  const feed = BigInt.asUintN(160, BigInt(e.feedAddress));
  // Pack feed address (160 bits) in the high 160 bits and the exponent in the low 96 bits.
  const packed = (feed << 96n) | BigInt.asUintN(96, BigInt(exponent));
  return `0x${packed.toString(16).padStart(64, "0")}`;
}

function firstNibble(token) {
  return (BigInt.asUintN(160, BigInt(token)) >> 156n).toString(10);
}

function buildGroups() {
  // Groups by leading hex nibble of the token address. Each branch is a small
  // integer comparison, which is cheaper and more compact than comparing a
  // full 20-byte boundary address.
  const boundaries = [3, 7, 10, 13];
  const groups = boundaries.map((bound) => ({ bound, entries: [] }));
  const lastGroup = { entries: [] };

  for (const e of sorted) {
    const nibble = firstNibble(e.token);
    let placed = false;
    for (const g of groups) {
      if (nibble < g.bound) {
        g.entries.push(e);
        placed = true;
        break;
      }
    }
    if (!placed) lastGroup.entries.push(e);
  }

  return { bounded: groups, last: lastGroup };
}

function emitEntry(e) {
  const packed = packEntry(e);
  return `            if (token == ${e.token}) packed = ${packed};`;
}

function buildFunction() {
  const { bounded, last } = buildGroups();
  const lines = [
    "    /// @dev Hardcoded Chainlink fallback feeds for GMX synthetic index tokens.",
    "    ///  Each entry is packed as `bytes32(feedAddress << 96 | exponent)` where",
    "    ///  `multiplier = 10 ** exponent`. Returns `(address(0), 0)` for unmapped tokens.",
    "    function getFallbackPriceFeed(address token) internal pure returns (address feed, uint256 multiplier) {",
    "        bytes32 packed;",
    "        uint256 nibble = uint160(token) >> 156;",
  ];

  for (let i = 0; i < bounded.length; ++i) {
    const g = bounded[i];
    const keyword = i === 0 ? "if" : "} else if";
    lines.push(`        ${keyword} (nibble < ${g.bound}) {`);
    for (const e of g.entries) {
      lines.push(emitEntry(e));
    }
  }

  if (last.entries.length > 0) {
    lines.push("        } else {");
    for (const e of last.entries) {
      lines.push(emitEntry(e));
    }
  }
  lines.push("        }");

  lines.push("        if (packed != bytes32(0)) {");
  lines.push("            uint256 packedData = uint256(packed);");
  lines.push("            feed = address(uint160(packedData >> 96));");
  lines.push("            multiplier = 10 ** (packedData & type(uint96).max);");
  lines.push("        }");
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
  const replacement = `${startMarker}\n\n${buildFunction()}\n\n${endMarker}`;

  fs.writeFileSync(CONTRACT, before + replacement + after, "utf8");
  console.log(
    `Patched ${CONTRACT} with ${sorted.length} packed fallback entries (${new Date().toISOString()})`,
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
