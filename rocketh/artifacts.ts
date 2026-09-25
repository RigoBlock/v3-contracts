import type {Artifact} from "@rocketh/core/types";
import {keccak256} from "ethers";
import fs from "fs";
import {fileURLToPath} from "url";
import path from "path";
import hre from "hardhat";
import {splitBytecode, joinBytecode, type BlobGap} from "./cbor";

/**
 * Canonical CBOR metadata blobs (see scripts/generate-canonical-cbor.ts).
 *
 * CREATE2 hashes the full init code including every CBOR metadata blob in it
 * (a creation code that embeds runtime code carries TWO — see cbor.ts). Hardhat 3
 * namespaces metadata differently from Hardhat 2 (a build-info format contract),
 * so the same source yields different blobs and a different CREATE2 address even
 * though the executable bytecode is identical. For contracts whose code is
 * unchanged since the authoritative deployment, we restore the authoritative
 * blobs so fresh chains reproduce the established addresses (Authority at
 * 0xe35129A1E0BdB913CF6Fd8332E9d3533b5F41472, PoolProxyFactory at
 * 0x8DE8895ddD702d9a216E640966A98e08c9228f24). Only the metadata stamps are
 * touched; the executable code deployed is always what the current toolchain
 * compiled from the current sources.
 */
type CanonicalEntry = {
  initSkeletonHash: string;
  initGaps: BlobGap[];
  deployedSkeletonHash?: string;
  deployedGaps?: BlobGap[];
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
 * Additionally applies the canonical CBOR blobs when the contract has an entry
 * and its executable code still matches the one the blobs were recorded for.
 * A mismatch means the contract changed after the blobs were generated; the
 * current blobs are kept (they are still identical across chains, since
 * metadata depends only on source and settings) and a warning is emitted so
 * the blobs can be regenerated from the authoritative chain.
 */
export async function readArtifact(name: string): Promise<Artifact> {
  const artifact = await hre.artifacts.readArtifact(name);
  const entry = loadCanonical()[name];
  if (entry) {
    const apply = (bytecode: string, skeletonHash: string, gaps?: BlobGap[]) => {
      const split = splitBytecode(bytecode);
      if (keccak256("0x" + split.skeleton) !== skeletonHash) return undefined;
      if (!gaps || gaps.length !== split.gaps.length) return undefined;
      return "0x" + joinBytecode(split.skeleton, gaps);
    };
    const bytecode = apply(artifact.bytecode, entry.initSkeletonHash, entry.initGaps);
    if (bytecode) {
      const deployedBytecode = artifact.deployedBytecode
        ? apply(artifact.deployedBytecode, entry.deployedSkeletonHash ?? "", entry.deployedGaps) ??
          artifact.deployedBytecode
        : artifact.deployedBytecode;
      return {...artifact, bytecode, deployedBytecode, metadata: ""} as unknown as Artifact;
    }
    console.warn(
      `canonical-cbor: ${name} executable code changed since the blobs were generated; ` +
        `keeping the current metadata. Regenerate with scripts/generate-canonical-cbor.ts.`,
    );
  }
  return {...artifact, metadata: ""} as unknown as Artifact;
}
