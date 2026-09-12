import type {Artifact} from "@rocketh/core/types";
import {keccak256} from "ethers";
import fs from "fs";
import {fileURLToPath} from "url";
import path from "path";
import hre from "hardhat";

/**
 * Canonical CBOR metadata tails (see scripts/generate-canonical-cbor.ts).
 *
 * CREATE2 hashes the full init code including its trailing CBOR metadata blob.
 * Hardhat 3 namespaces metadata differently from Hardhat 2 (a build-info format
 * contract), so the same source yields a different blob and a different CREATE2
 * address even though the executable bytecode is identical. For contracts whose
 * code is unchanged since the authoritative deployment, we restore the
 * authoritative tail so fresh chains reproduce the established addresses
 * (e.g. Authority at 0xe35129A1E0BdB913CF6Fd8332E9d3533b5F41472). Only the
 * metadata stamp is touched; the executable code deployed is always what the
 * current toolchain compiled from the current sources.
 */
type CanonicalEntry = {tail: string; initCodeHash: string};

const stripCbor = (hex: string) => {
  const len = parseInt(hex.slice(-4), 16);
  return hex.slice(0, hex.length - 4 - len * 2);
};

let canonical: Record<string, CanonicalEntry> | undefined;
function loadCanonical(): Record<string, CanonicalEntry> {
  if (canonical === undefined) {
    const p = path.join(path.dirname(fileURLToPath(import.meta.url)), "canonical-cbor.json");
    canonical = fs.existsSync(p)
      ? (JSON.parse(fs.readFileSync(p, "utf8")) as Record<string, CanonicalEntry>)
      : {};
  }
  return canonical;
}

/**
 * Read a Hardhat 3 artifact and adapt it to rocketh's `Artifact` type.
 *
 * Rocketh's type requires a `metadata` field (consumed by verification
 * extensions only — nothing at deploy time reads it), while Hardhat 3
 * artifacts no longer carry solc metadata. Default it to an empty string.
 *
 * Additionally applies the canonical CBOR tail when the contract has an entry
 * and its executable init code still matches the one the tail was recorded
 * for. A mismatch means the contract changed after the tails were generated;
 * the current tail is kept (it is still identical across chains, since
 * metadata depends only on source and settings) and a warning is emitted so
 * the tails can be regenerated from the authoritative chain.
 */
export async function readArtifact(name: string): Promise<Artifact> {
  const artifact = await hre.artifacts.readArtifact(name);
  const entry = loadCanonical()[name];
  if (entry) {
    const stripped = stripCbor(artifact.bytecode);
    if (keccak256(stripped) === entry.initCodeHash) {
      const strippedDeployed = artifact.deployedBytecode ? stripCbor(artifact.deployedBytecode) : undefined;
      return {
        ...artifact,
        bytecode: stripped + entry.tail,
        deployedBytecode: strippedDeployed ? strippedDeployed + entry.tail : artifact.deployedBytecode,
        metadata: "",
      } as unknown as Artifact;
    }
    console.warn(
      `canonical-cbor: ${name} executable code changed since the tails were generated; ` +
        `keeping the current metadata tail. Regenerate with scripts/generate-canonical-cbor.ts.`,
    );
  }
  return {...artifact, metadata: ""} as unknown as Artifact;
}
