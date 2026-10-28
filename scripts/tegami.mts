// SPDX-License-Identifier: MIT
// Copyright: 2024-2026 NiceBots.xyz

import { tegami } from "tegami";
import { runCli } from "tegami/cli";
import { github } from "tegami/plugins/github";
import { linkedGenerator } from "./tegami-changelog.mts";
import { images } from "./tegami-images.mts";
import { releases } from "./tegami-releases.mts";

const repo = process.env.GITHUB_REPOSITORY || "nicebots-xyz/hippo";
const versionTitle = "chore(release): version packages";

const paper = tegami({
  npm: { updateLockFile: false },
  generator: linkedGenerator({ repo }),
  plugins: [
    releases(),
    images(),
    github({
      repo,
      versionPr: {
        base: "main",
        // The repository requires semantic pull request titles.
        create: () => ({ title: versionTitle }),
        commit: ({ type }) => (type === "version-packages" ? { title: versionTitle } : undefined),
      },
    }),
  ],
});

await runCli(paper);
