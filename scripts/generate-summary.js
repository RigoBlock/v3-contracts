#!/usr/bin/env node
// Generates/updates a GitBook SUMMARY.md section from a directory of markdown files.
// Usage: node generate-summary.js <api-dir> <summary-path>

const fs = require("fs");
const path = require("path");

const API_DIR = process.argv[2] || "contracts/api";
const SUMMARY_PATH = process.argv[3] || "SUMMARY.md";
const MARKER_START = "<!-- AUTO-GENERATED-API-START -->";
const MARKER_END = "<!-- AUTO-GENERATED-API-END -->";

function toRelative(filePath) {
  return path.relative(path.dirname(SUMMARY_PATH), filePath).replace(/\\/g, "/");
}

function titleCase(name) {
  return name.charAt(0).toUpperCase() + name.slice(1);
}

function walk(dir, indent) {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  const dirs = entries
    .filter((e) => e.isDirectory())
    .sort((a, b) => a.name.localeCompare(b.name));
  const files = entries
    .filter((e) => e.isFile() && e.name.endsWith(".md"))
    .sort((a, b) => a.name.localeCompare(b.name));

  const lines = [];

  for (const file of files) {
    if (file.name === "README.md") continue;
    const relPath = toRelative(path.join(dir, file.name));
    const name = file.name.replace(/\.md$/, "");
    lines.push(`${indent}* [${name}](${relPath})`);
  }

  for (const subdir of dirs) {
    const subdirPath = path.join(dir, subdir.name);
    const readmePath = path.join(subdirPath, "README.md");
    const hasReadme = fs.existsSync(readmePath);
    const relPath = toRelative(readmePath);

    if (hasReadme) {
      lines.push(`${indent}* [${titleCase(subdir.name)}](${relPath})`);
    } else {
      lines.push(`${indent}* ${titleCase(subdir.name)}`);
    }

    lines.push(...walk(subdirPath, indent + "  "));
  }

  return lines;
}

function generateApiSection() {
  const rootReadme = toRelative(path.join(API_DIR, "README.md"));
  const lines = [`* [Solidity API Reference](${rootReadme})`];

  const entries = fs.readdirSync(API_DIR, { withFileTypes: true });
  const dirs = entries
    .filter((e) => e.isDirectory())
    .sort((a, b) => a.name.localeCompare(b.name));
  const files = entries
    .filter((e) => e.isFile() && e.name.endsWith(".md"))
    .sort((a, b) => a.name.localeCompare(b.name));

  for (const subdir of dirs) {
    const subdirPath = path.join(API_DIR, subdir.name);
    lines.push(`  * ${titleCase(subdir.name)}`);
    lines.push(...walk(subdirPath, "    "));
  }

  for (const file of files) {
    if (file.name === "README.md") continue;
    const relPath = toRelative(path.join(API_DIR, file.name));
    const name = file.name.replace(/\.md$/, "");
    lines.push(`  * [${name}](${relPath})`);
  }

  return lines.join("\n");
}

function updateSummary() {
  let summary = "";
  if (fs.existsSync(SUMMARY_PATH)) {
    summary = fs.readFileSync(SUMMARY_PATH, "utf8");
  }

  const generatedSection = `${MARKER_START}\n${generateApiSection()}\n${MARKER_END}`;

  if (summary.includes(MARKER_START) && summary.includes(MARKER_END)) {
    summary = summary.replace(
      new RegExp(`${MARKER_START}[\\s\\S]*${MARKER_END}`),
      generatedSection
    );
  } else {
    summary = summary.trimEnd() + "\n\n" + generatedSection + "\n";
  }

  fs.writeFileSync(SUMMARY_PATH, summary);
  console.log(`Updated ${SUMMARY_PATH}`);
}

updateSummary();
