/**
 * Solc CBOR metadata blob handling for init/runtime bytecode.
 *
 * A compiled bytecode string can contain MORE THAN ONE metadata blob: the
 * creation code of a contract embeds the runtime bytecode as data (for
 * contracts that deploy or proxy other contracts), and each of the two carries
 * its own `a26469706673...` blob followed by a 2-byte big-endian length.
 * CREATE2 hashes the full init code, so EVERY blob contributes to the
 * deterministic address — canonicalizing or comparing bytecode requires
 * removing all of them, not just the trailing one.
 *
 * A blob is accepted only when its self-declared length checks out (the 2-byte
 * suffix right after the map equals the map's byte length), so arbitrary code
 * that happens to contain the marker bytes is never treated as metadata.
 */

export type BlobGap = {
  /** Offset in the skeleton (blob-free hex) where the blob is re-inserted. */
  offset: number;
  /** Full blob hex including the 2-byte length suffix. */
  blob: string;
};

export type SplitBytecode = {
  /** Bytecode with all metadata blobs removed. */
  skeleton: string;
  gaps: BlobGap[];
};

const MARKERS = [
  // a2 64 "ipfs" 58 22 12 20 — modern solc ipfs metadata
  "a2646970667358221220",
  // a1 65 "bzzr0" 58 20 — legacy swarm metadata
  "a165627a7a72305820",
  // a1 65 "bzzr1" 31 58 20 — legacy swarm metadata
  "a165627a7a7231" + "315820",
];

/** Hex chars of one metadata blob starting at `start`, or -1 if invalid. */
function blobLengthAt(hex: string, start: number): number {
  const marker = MARKERS.find((m) => hex.startsWith(m, start));
  if (!marker) return -1;
  let cursor = start + marker.length + 64; // 32-byte content hash
  // optional solc-version field: 64 "solc" 43 <3 bytes>
  if (hex.startsWith("64736f6c6343", cursor)) {
    cursor += 12 + 6;
  }
  const declared = parseInt(hex.slice(cursor, cursor + 4), 16);
  if ((cursor - start) / 2 !== declared) return -1;
  return cursor + 4 - start;
}

/**
 * Remove every metadata blob, returning the skeleton and, for each blob, its
 * reinsertion offset and content. `joinBytecode(skeleton, gaps)` on the same
 * input returns the original string, so no information is lost.
 */
export function splitBytecode(bytecode: string): SplitBytecode {
  const hex = bytecode.startsWith("0x") ? bytecode.slice(2) : bytecode;
  const gaps: BlobGap[] = [];
  const parts: string[] = [];
  let skeletonLength = 0;
  let copied = 0;
  let pos = 0;
  while (pos < hex.length) {
    const len = blobLengthAt(hex, pos);
    if (len > 0) {
      const part = hex.slice(copied, pos);
      parts.push(part);
      skeletonLength += part.length;
      gaps.push({offset: skeletonLength, blob: hex.slice(pos, pos + len)});
      pos += len;
      copied = pos;
    } else {
      pos += 2;
    }
  }
  parts.push(hex.slice(copied));
  return {skeleton: parts.join(""), gaps};
}

/** Re-insert blobs at their skeleton offsets. */
export function joinBytecode(skeleton: string, gaps: BlobGap[]): string {
  let out = "";
  let copied = 0;
  for (const g of gaps) {
    out += skeleton.slice(copied, g.offset) + g.blob;
    copied = g.offset;
  }
  return out + skeleton.slice(copied);
}
