import fs from "fs";
import path from "path";
import hre from "hardhat";
import {keccak256} from "ethers";

/**
 * Generates rocketh/canonical-cbor.json from an authoritative chain's deployment
 * records (default: mainnet).
 *
 * Why this exists
 * ---------------
 * CREATE2 addresses are a hash of the full init code, which ends with a CBOR
 * metadata blob. That blob's IPFS hash depends on the metadata JSON, which
 * Hardhat 3 namespaces differently from Hardhat 2 (`project/contracts/...`
 * source names, context-prefixed remappings — a build-info format contract
 * that cannot be configured away). Same source + same compiler settings
 * therefore produces a different blob under Hardhat 3, and a different
 * CREATE2 address, even though the executable bytecode is byte-identical.
 *
 * Cross-chain address parity ("Authority at 0xe351... on every chain") is a
 * protocol requirement, so for each contract whose executable code is
 * UNCHANGED since the authoritative deployment, we canonicalize the metadata
 * stamp: the deploy pipeline swaps the artifact's CBOR tail for the
 * authoritative one. The init code then matches the already-deployed chains
 * byte-for-byte and CREATE2 reproduces the same address. Contracts whose code
 * legitimately changed keep the current build's tail: their metadata depends
 * only on source + settings (never on the chain), so every chain still
 * computes the same address for them.
 *
 * Run this after deploying an upgrade to the authoritative chain so future
 * chains reproduce the new canonical addresses:
 *
 *   npx hardhat run scripts/generate-canonical-cbor.ts --network hardhat
 *
 * (CANONICAL_CHAIN env var overrides `mainnet`.)
 */

const stripCbor = (hex: string) => {
  const len = parseInt(hex.slice(-4), 16);
  return hex.slice(0, hex.length - 4 - len * 2);
};
const cborTail = (hex: string) => hex.slice(stripCbor(hex).length);

async function main() {
  const chain = process.env.CANONICAL_CHAIN || "mainnet";
  const dir = path.join("deployments", chain);
  const out: Record<string, {tail: string; initCodeHash: string}> = {};
  let matched = 0;
  let skipped = 0;

  for (const file of fs.readdirSync(dir)) {
    if (!file.endsWith(".json")) continue;
    const name = file.replace(".json", "");
    const record = JSON.parse(fs.readFileSync(path.join(dir, file), "utf8"));
    let artifact;
    try {
      artifact = await hre.artifacts.readArtifact(name);
    } catch {
      continue; // no matching artifact (e.g. imported deployment records)
    }
    if (stripCbor(record.bytecode.toLowerCase()) === stripCbor(artifact.bytecode.toLowerCase())) {
      out[name] = {
        tail: cborTail(record.bytecode),
        initCodeHash: keccak256(stripCbor(artifact.bytecode)),
      };
      matched++;
    } else {
      console.log(`skip ${name}: executable code changed since the ${chain} deployment (new canonical address)`);
      skipped++;
    }
  }

  const outPath = path.join("rocketh", "canonical-cbor.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n");
  console.log(`wrote ${outPath}: ${matched} canonical tails (${skipped} changed contracts keep the current tail)`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
