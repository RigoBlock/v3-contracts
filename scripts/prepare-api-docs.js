#!/usr/bin/env node
// Adapts `forge doc` output (a vocs scaffold with .mdx pages under
// src/pages/contracts/) to the GitBook-compatible tree that
// scripts/publish-docs.sh consumes: docs/api/<group>/**.md.
// Usage: node prepare-api-docs.js [rawDir] [outDir]

import fs from "node:fs";
import path from "node:path";

const RAW_DIR = process.argv[2] || "docs/api-raw/src/pages/contracts";
const OUT_DIR = process.argv[3] || "docs/api";

// Directories that make up the public API. Test contracts and mocks are
// excluded from the published docs.
const KEEP = new Set(["protocol", "governance", "rigoblockToken", "staking", "tokens", "utils"]);

function rmrf(dir) {
  fs.rmSync(dir, {recursive: true, force: true});
}

function copyMdxAsMd(src, dst) {
  for (const entry of fs.readdirSync(src, {withFileTypes: true})) {
    const s = path.join(src, entry.name);
    if (entry.isDirectory()) {
      copyMdxAsMd(s, path.join(dst, entry.name));
    } else if (entry.name.endsWith(".mdx")) {
      fs.mkdirSync(dst, {recursive: true});
      fs.copyFileSync(s, path.join(dst, entry.name.replace(/\.mdx$/, ".md")));
    }
  }
}

if (!fs.existsSync(RAW_DIR)) {
  console.error(`forge doc output not found at ${RAW_DIR}; run \`forge doc --out docs/api-raw\` first`);
  process.exit(1);
}

rmrf(OUT_DIR);
for (const group of fs.readdirSync(RAW_DIR, {withFileTypes: true})) {
  if (!group.isDirectory() || !KEEP.has(group.name)) continue;
  copyMdxAsMd(path.join(RAW_DIR, group.name), path.join(OUT_DIR, group.name));
}
// generate-summary.js links the API root to a README.md.
fs.writeFileSync(
  path.join(OUT_DIR, "README.md"),
  "# Solidity API Reference\n\nAuto-generated from the contracts' NatSpec via `forge doc`.\n",
);
console.log(`wrote ${OUT_DIR}`);
