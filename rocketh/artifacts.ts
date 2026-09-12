import type {Artifact} from "@rocketh/core/types";
import hre from "hardhat";

/**
 * Read a Hardhat 3 artifact and adapt it to rocketh's `Artifact` type.
 *
 * Rocketh's type requires a `metadata` field (consumed by verification
 * extensions only — nothing at deploy time reads it), while Hardhat 3
 * artifacts no longer carry solc metadata. Default it to an empty string.
 */
export async function readArtifact(name: string): Promise<Artifact> {
  const artifact = await hre.artifacts.readArtifact(name);
  return {...artifact, metadata: ""} as unknown as Artifact;
}
