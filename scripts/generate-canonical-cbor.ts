import fs from "fs";
import path from "path";
import hre from "hardhat";
import { keccak256 } from "ethers";
import { splitBytecode } from "../rocketh/cbor";
/**
 * Generates rocketh/canonical-cbor.json from an authoritative chain's deployment
 * records (default: mainnet).
 *
 * Why this exists
 * ---------------
 * CREATE2 addresses are a hash of the full init code, which contains one CBOR
 * metadata blob per embedded bytecode (a creation code that embeds runtime code
 * carries two). Those blobs' content hashes depend on the metadata JSON, which
 * Hardhat 3 namespaces differently from Hardhat 2 (`project/contracts/...`
 * source names, context-prefixed remappings — a build-info format contract that
 * cannot be configured away). Same source + same compiler settings therefore
 * produces different blobs under Hardhat 3, and a different CREATE2 address,
 * even though the executable bytecode is byte-identical.
 *
 * Cross-chain address parity ("Authority at 0xe351... on every chain") is a
 * protocol requirement, so for each contract whose executable code is
 * UNCHANGED since the authoritative deployment, we canonicalize the metadata
 * stamps: the deploy pipeline swaps the artifact's blobs for the authoritative
 * ones. The init code then matches the already-deployed chains byte-for-byte
 * and CREATE2 reproduces the same address. Contracts whose code legitimately
 * changed keep the current build's blobs: their metadata depends only on
 * source + settings (never on the chain), so every chain still computes the
 * same address for them.
 *
 * Each entry records the solc version that produced the current build. This is
 * what makes the redeploy rule enforceable: bumping solc changes the metadata
 * even when the executable code is byte-identical, and the rule requires such
 * contracts to be redeployed with the new compiler (they may carry compiler
 * bug fixes invisible at source level). readArtifact refuses to restore blobs
 * across a compiler mismatch, so the new metadata takes effect and CREATE2
 * yields a fresh address. A solc bump on an extension therefore requires the
 * usual salt + VERSION bump (see AGENTS.md).
 *
 * Run this after deploying an upgrade to the authoritative chain so future
 * chains reproduce the new canonical addresses:
 *
 *   npx hardhat run scripts/generate-canonical-cbor.ts --network hardhat
 *
 * (CANONICAL_CHAIN env var overrides `mainnet`.)
 */

async function main() {
  const chain = process.env.CANONICAL_CHAIN || "mainnet";
  const dir = path.join("deployments", chain);
  const out: Record<string, unknown> = {};
  let matched = 0;
  let skipped = 0;

  // Records the compiler that produced the AUTHORITATIVE DEPLOYMENT, parsed
  // from the deployment record's buildInfoId (`solc-0_8_28-...`). The redeploy
  // rule compares it against the current build's compiler: bumping solc
  // changes the metadata even when the executable code is byte-identical, and
  // such contracts MUST be redeployed with the new compiler (readArtifact
  // refuses to restore blobs recorded under a different compiler version).
  // The short version is enough for the rule and avoids depending on old
  // build-info files still being present on disk. Falls back to the current
  // artifact's compiler for records that lack a buildInfoId.
  const solcVersionOf = (buildInfoId?: string): string | undefined => {
    const m = buildInfoId?.match(/^solc-(\d+_\d+_\d+)-/);
    return m ? m[1].replace(/_/g, ".") : undefined;
  };

  for (const file of fs.readdirSync(dir)) {
    if (!file.endsWith(".json")) continue;
    const name = file.replace(".json", "");
    const record = JSON.parse(fs.readFileSync(path.join(dir, file), "utf8"));
    if (!record.bytecode) continue;
    let artifact;
    try {
      artifact = await hre.artifacts.readArtifact(name);
    } catch {
      continue; // no matching artifact (e.g. imported deployment records)
    }
    const artifactBytecode =
      typeof artifact.bytecode === "string"
        ? artifact.bytecode
        : artifact.bytecode?.object;
    if (!artifactBytecode) continue;
    const recordInit = splitBytecode(record.bytecode.toLowerCase());
    const artifactInit = splitBytecode(artifactBytecode.toLowerCase());
    if (recordInit.skeleton !== artifactInit.skeleton) {
      console.log(
        `skip ${name}: executable code changed since the ${chain} deployment (new canonical address)`,
      );
      skipped++;
      continue;
    }
    const entry: Record<string, unknown> = {
      initSkeletonHash: keccak256("0x" + artifactInit.skeleton),
      initGaps: recordInit.gaps,
      solcVersion:
        solcVersionOf(record.buildInfoId) ?? solcVersionOf(artifact.buildInfoId),
    };
    const recordDeployed = record.deployedBytecode?.toLowerCase();
    const artifactDeployed =
      artifact.deployedBytecode &&
      (typeof artifact.deployedBytecode === "string"
        ? artifact.deployedBytecode
        : artifact.deployedBytecode?.object);
    if (recordDeployed && artifactDeployed) {
      const recordRuntime = splitBytecode(recordDeployed);
      const artifactRuntime = splitBytecode(artifactDeployed);
      if (recordRuntime.skeleton === artifactRuntime.skeleton) {
        entry.deployedSkeletonHash = keccak256("0x" + artifactRuntime.skeleton);
        entry.deployedGaps = recordRuntime.gaps;
      }
    }
    out[name] = entry;
    matched++;
  }

  const outPath = path.join("rocketh", "canonical-cbor.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n");
  console.log(
    `wrote ${outPath}: ${matched} canonical blob sets (${skipped} changed contracts keep current blobs)`,
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
