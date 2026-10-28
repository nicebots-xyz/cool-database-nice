// SPDX-License-Identifier: MIT
// Copyright: 2024-2026 NiceBots.xyz

import { readdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { WorkspacePackage } from "tegami";
import type { TegamiPlugin } from "tegami";

const VERSION_FILE = "VERSION";
const SEMVER = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;

/**
 * A release line backed by a `releases/<name>/VERSION` file. Its `CHANGELOG.md` is written by Tegami
 * into the same directory. How a line is published is up to other plugins (see tegami-images.mts).
 */
export class ReleasePackage extends WorkspacePackage {
  readonly manager = "release";
  readonly name: string;
  readonly path: string;
  private current: string;

  constructor(dir: string, version: string) {
    super();
    this.path = dir;
    this.name = path.basename(dir);
    this.current = version;
  }

  get version(): string {
    return this.current;
  }

  setVersion(version: string): void {
    this.current = version;
  }

  async write(): Promise<void> {
    await writeFile(path.join(this.path, VERSION_FILE), `${this.current}\n`);
  }
}

export interface ReleasesPluginOptions {
  /**
   * Directory containing one sub-directory per release line, relative to the workspace root.
   *
   * @default "releases"
   */
  dir?: string;
}

/** Discovers every `<dir>/<name>/VERSION` as a package named `<name>`, and writes bumped versions back. */
export function releases({ dir = "releases" }: ReleasesPluginOptions = {}): TegamiPlugin {
  return {
    name: "releases",
    async resolve() {
      const root = path.resolve(this.cwd, dir);
      const entries = await readdir(root, { withFileTypes: true }).catch(() => []);

      for (const entry of entries) {
        if (!entry.isDirectory()) continue;

        const packagePath = path.join(root, entry.name);
        const version = await readFile(path.join(packagePath, VERSION_FILE), "utf8")
          .then((content) => content.trim())
          .catch(() => undefined);
        if (version === undefined) continue;
        if (!SEMVER.test(version)) {
          throw new Error(`[releases] "${entry.name}/${VERSION_FILE}" is not a valid version: "${version}"`);
        }

        this.graph.add(new ReleasePackage(packagePath, version));
      }
    },
    async applyDraft(draft) {
      await Promise.all(
        this.graph.getPackages().map(async (pkg) => {
          if (!(pkg instanceof ReleasePackage)) return;

          const bumped = draft.getPackageDraft(pkg.id)?.bumpVersion(pkg);
          if (!bumped || bumped === pkg.version) return;

          pkg.setVersion(bumped);
          await pkg.write();
        }),
      );
    },
  };
}
