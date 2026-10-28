// SPDX-License-Identifier: MIT
// Copyright: 2026 NiceBots.xyz

import { execFileSync } from "node:child_process";
import path from "node:path";
import type { LogGenerator } from "tegami";

/** A squash-merged commit's subject ends with its pull request: `feat: something (#12)`. */
const PULL_REQUEST = /\(#(\d+)\)$/;

/**
 * Tegami's default changelog layout, with every entry linked to the pull request that added it.
 *
 * The repository only allows squash merges, so the commit that added an entry file is its pull request's
 * squash commit. Entries without such a commit (e.g. generated in memory) are left unlinked.
 */
export function linkedGenerator({ repo }: { repo: string }): LogGenerator {
  return {
    generate({ pkg, packageDraft }) {
      const link = (filename: string): string => {
        const file = path.relative(this.cwd, path.join(this.changelogDir, filename));
        let subject = "";
        try {
          subject = execFileSync("git", ["log", "--diff-filter=A", "-1", "--format=%s", "--", file], {
            cwd: this.cwd,
            encoding: "utf8",
          }).trim();
        } catch {
          return "";
        }
        const number = PULL_REQUEST.exec(subject)?.[1];
        return number ? ` ([#${number}](https://github.com/${repo}/pull/${number}))` : "";
      };

      const lines = [`## ${pkg.name}@${pkg.version}`, ""];
      for (const entry of packageDraft.changelogs ?? []) {
        let sectionDepth = 4;
        if (entry.subject) lines.push(`### ${entry.subject}`, "");
        else sectionDepth--;
        const suffix = entry.virtual ? "" : link(entry.filename);
        for (const section of entry.sections) {
          lines.push(`${"#".repeat(sectionDepth)} ${section.title}${suffix}`, "", section.content, "");
        }
      }
      return lines.join("\n").trim();
    },
  };
}
