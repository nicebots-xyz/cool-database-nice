// SPDX-License-Identifier: MIT
// Copyright: 2026 NiceBots.xyz

import { readFileSync } from "node:fs";

/**
 * Prints the changelog section for the packages that changed between two images, from their
 * `hippo-manifest` outputs (`<kind> <name> <version>` lines). Prints nothing when nothing changed.
 *
 * usage: node scripts/package-diff.mts <previous-manifest> <candidate-manifest>
 */
const [previousFile, candidateFile] = process.argv.slice(2);
if (!previousFile || !candidateFile) throw new Error("usage: package-diff.mts <previous-manifest> <candidate-manifest>");

function parse(file: string): Map<string, string> {
  const packages = new Map<string, string>();
  for (const line of readFileSync(file, "utf8").split("\n")) {
    const [kind, name, version] = line.trim().split(" ");
    if (kind && name && version) packages.set(`${kind} ${name}`, version);
  }
  return packages;
}

const previous = parse(previousFile);
const candidate = parse(candidateFile);
const lines: string[] = [];
for (const key of [...new Set([...previous.keys(), ...candidate.keys()])].sort()) {
  const [from, to] = [previous.get(key), candidate.get(key)];
  if (from === to) continue;
  const [kind, name] = key.split(" ");
  const change = !from ? `${to} (added)` : !to ? `${from} (removed)` : `${from} → ${to}`;
  lines.push(`- \`${name}\` (${kind}): ${change}`);
}

if (lines.length > 0) {
  console.log(`<details>\n<summary>${lines.length} package${lines.length === 1 ? "" : "s"} changed in the image</summary>\n\n${lines.join("\n")}\n\n</details>`);
}
