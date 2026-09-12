#!/usr/bin/env node
// Adapts `hardhat markup` output (one .md per contract, mirroring the
// contracts/ source tree under docs/api-raw/) to the GitBook-compatible tree
// that scripts/publish-docs.sh consumes: docs/api/<group>/**.md.
// Usage: node prepare-api-docs.js [rawDir] [outDir]

import fs from "node:fs";
import path from "node:path";

const RAW_DIR = process.argv[2] || "docs/api-raw/contracts";
const OUT_DIR = process.argv[3] || "docs/api";

// Directories that make up the public API. Test contracts and mocks are
// excluded from the published docs (hardhat-markup skipFiles already drops
// them from the raw output; this is a second line of defence).
const KEEP = new Set([
  "protocol",
  "governance",
  "rigoToken",
  "staking",
  "tokens",
  "utils",
]);

const README = `---
description: Auto-generated from the contracts' NatSpec via @solarity/hardhat-markup.
---

# Solidity API Reference
`;

if (!fs.existsSync(RAW_DIR)) {
  console.error(
    `hardhat-markup output not found at ${RAW_DIR}; run \`npx hardhat markup --outdir docs/api-raw\` first`,
  );
  process.exit(1);
}

fs.rmSync(OUT_DIR, { recursive: true, force: true });

function copyMd(src, dst) {
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const s = path.join(src, entry.name);
    if (entry.isDirectory()) {
      copyMd(s, path.join(dst, entry.name));
    } else if (entry.name.endsWith(".md")) {
      fs.mkdirSync(dst, { recursive: true });
      fs.copyFileSync(s, path.join(dst, entry.name));
    }
  }
}

for (const group of fs.readdirSync(RAW_DIR, { withFileTypes: true })) {
  if (!group.isDirectory() || !KEEP.has(group.name)) continue;
  copyMd(path.join(RAW_DIR, group.name), path.join(OUT_DIR, group.name));
}

fs.writeFileSync(path.join(OUT_DIR, "README.md"), README);

const count = (dir) =>
  fs
    .readdirSync(dir, { withFileTypes: true })
    .reduce(
      (n, e) =>
        e.isDirectory()
          ? n + count(path.join(dir, e.name))
          : n + (e.name.endsWith(".md") ? 1 : 0),
      0,
    );
console.log(`prepared ${OUT_DIR}: ${count(OUT_DIR)} markdown files`);
