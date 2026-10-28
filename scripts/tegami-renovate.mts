// SPDX-License-Identifier: MIT
// Copyright: 2026 NiceBots.xyz

import { execFileSync } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";

/**
 * Writes the changelog entry of a Renovate pull request: `.tegami/<branch-slug>.md`.
 *
 * The entry is a pure function of the pull request (its title, branch and diff), so re-running this after
 * Renovate rebases or retargets the branch rewrites the same file with up-to-date content.
 * Only pull requests that change shipped content (images/, deploy/, docker-bake.hcl) get one, like any other pull request.
 * The entry targets the release line the change belongs to: `hippo-ext` when only images/ext/ changed,
 * `hippo` otherwise (hippo-ext follows hippo). Every dependency update is a patch release, lock file
 * maintenance included; a reviewer can raise the bump in the entry file.
 * Expects `PR_TITLE`, `PR_BRANCH` and `PR_BASE` (base commit) in the environment.
 */
const SHIPPED = ["images", "deploy", "docker-bake.hcl"];
const EXTENSIONS = "images/ext/extensions.yaml";

const title = process.env.PR_TITLE?.trim() ?? "";
const branch = process.env.PR_BRANCH?.trim() ?? "";
const base = process.env.PR_BASE?.trim() ?? "";

// Renovate titles its pull requests `<type>(deps): <subject>`.
const subject = /^\w+\(deps[\w-]*\)!?: (.+)$/.exec(title)?.[1];
if (!subject) {
  console.log(`"${title}" is not a dependency update.`);
  process.exit(0);
}

if (!base) throw new Error("PR_BASE is required.");
const shipped = execFileSync("git", ["diff", "--name-only", base, "HEAD", "--", ...SHIPPED], { encoding: "utf8" })
  .split("\n")
  .filter(Boolean);
if (shipped.length === 0) {
  console.log("No shipped content changed, no entry needed.");
  process.exit(0);
}
const line = shipped.every((file) => file.startsWith("images/ext/")) ? "hippo-ext" : "hippo";

const slug = branch.toLowerCase().replace(/[^a-z0-9.]+/g, "-").replace(/^-+|-+$/g, "");
if (!slug) throw new Error("PR_BRANCH is required.");

interface Extension {
  name: string;
  version: string;
  upstream?: string;
}

/** Parses the flat, fixed-order extensions file (see its header) at a given revision. */
function extensions(revision: string): Map<string, Extension> {
  let text = "";
  try {
    text = execFileSync("git", ["show", `${revision}:${EXTENSIONS}`], { encoding: "utf8" });
  } catch {
    return new Map();
  }
  const byPackage = new Map<string, Extension>();
  let name = "";
  let pkg = "";
  for (const line of text.split("\n")) {
    const top = /^([\w-]+):\s*$/.exec(line);
    if (top) name = top[1];
    const field = /^\s+(package|version|upstream): (\S+)/.exec(line);
    if (!field) continue;
    if (field[1] === "package") {
      pkg = field[2];
      byPackage.set(pkg, { name, version: "" });
    } else if (pkg) {
      const ext = byPackage.get(pkg)!;
      if (field[1] === "version") ext.version = field[2];
      else ext.upstream = field[2];
    }
  }
  return byPackage;
}

/** `1:0.8.7-1.pgdg13+1` → `0.8.7`: drops the epoch, Debian revision and repack suffix. */
function upstreamVersion(debian: string): string {
  return debian.replace(/^\d+:/, "").replace(/-[^-]*$/, "").replace(/[+~](dfsg|ds)\d*$/, "");
}

const before = extensions(base);
const after = extensions("HEAD");
const bullets = [...after]
  .filter(([pkg, ext]) => before.get(pkg)?.version !== ext.version)
  .map(([pkg, ext]) => {
    const from = before.get(pkg);
    const change = from ? `${upstreamVersion(from.version)} → ${upstreamVersion(ext.version)}` : `added at ${upstreamVersion(ext.version)}`;
    const notes = ext.upstream ? ` ([release notes](${ext.upstream}/releases))` : "";
    return `- ${ext.name} ${change}${notes}`;
  });

const heading = subject.charAt(0).toUpperCase() + subject.slice(1);
const body = bullets.length > 0 ? `\n${bullets.join("\n")}\n` : "";
const content = `---\npackages:\n  ${line}: patch\n---\n\n### ${heading}\n${body}`;

await mkdir(".tegami", { recursive: true });
await writeFile(`.tegami/${slug}.md`, content);
console.log(`Wrote .tegami/${slug}.md`);
