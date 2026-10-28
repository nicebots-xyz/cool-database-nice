// SPDX-License-Identifier: MIT
// Copyright: 2026 NiceBots.xyz

import { execFile } from "node:child_process";
import { copyFile, readFile } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import { PackagePublishTask } from "tegami";
import type { ChangelogEntry, PackagePublishTaskResult, PublishTaskContext, TegamiPlugin } from "tegami";
import { ReleasePackage } from "./tegami-releases.mts";

const run = promisify(execFile);

const BASE = "hippo";
const EXT = "hippo-ext";

/**
 * What every release line ships. `inputs` are the paths its image is built from: a release is refused when
 * they changed since the candidate was built. `tags` are the tags a release points at the candidate.
 */
const LINES: Record<string, { inputs: string[]; tags: (pg: string, version: string) => string[] }> = {
  [BASE]: { inputs: ["images/base", "deploy", "docker-bake.hcl"], tags: (pg, v) => [`${pg}-${v}`, pg] },
  // ext is built on the base of the same build, so it depends on every image input.
  [EXT]: { inputs: ["images", "deploy", "docker-bake.hcl"], tags: (pg, v) => [`${pg}-ext-${v}`, `${pg}-ext`] },
};

/** `releases/<line>/CANDIDATE`: what a pending release ships. `key=value` lines. */
interface Candidate {
  /** commit the image was built from */
  source: string;
  /** PostgreSQL major, the tag prefix */
  pg: string;
  /** `<repository>@sha256:…` */
  image: string;
}

async function readCandidate(file: string): Promise<Candidate> {
  const fields = Object.fromEntries(
    (await readFile(file, "utf8"))
      .split("\n")
      .filter((line) => line.includes("="))
      .map((line) => [line.slice(0, line.indexOf("=")), line.slice(line.indexOf("=") + 1).trim()]),
  );
  for (const key of ["source", "pg", "image"]) {
    if (!fields[key]) throw new Error(`[images] ${file} has no "${key}"`);
  }
  return fields as unknown as Candidate;
}

async function remoteDigest(ref: string): Promise<string | undefined> {
  try {
    const { stdout } = await run("docker", ["buildx", "imagetools", "inspect", ref, "--format", "{{json .Manifest}}"]);
    return JSON.parse(stdout).digest;
  } catch {
    return undefined;
  }
}

/** A changelog entry generated in memory, e.g. from the candidate's package diff. */
function virtualEntry(line: string, title: string, content: string): ChangelogEntry {
  const filename = `${line}-${title.toLowerCase().replace(/\W+/g, "-")}.md`;
  return {
    id: filename,
    filename,
    packages: new Map([[line, { type: "patch" }]]),
    sections: [{ depth: 3, title, content }],
    virtual: true,
    getRawContent: () => `---\npackages:\n  ${line}: patch\n---\n\n### ${title}\n\n${content}\n`,
  };
}

/**
 * Publishes a release line by pointing its release tags at the candidate's digest. Images are never
 * rebuilt: what was tested is what ships. Tegami creates the git tag and GitHub release only after this
 * succeeds.
 */
class ImagePromoteTask extends PackagePublishTask<ReleasePackage> {
  private async target({ context }: Pick<PublishTaskContext, "context">) {
    const candidate = await readCandidate(path.join(this.pkg.path, "CANDIDATE"));
    const repository = candidate.image.slice(0, candidate.image.indexOf("@"));
    const digest = candidate.image.slice(candidate.image.indexOf("@") + 1);
    const tags = LINES[this.pkg.name].tags(candidate.pg, this.pkg.version).map((tag) => `${repository}:${tag}`);
    return { candidate, digest, tags, cwd: context.cwd };
  }

  async publish(opts: PublishTaskContext): Promise<PackagePublishTaskResult> {
    const { candidate, digest, tags, cwd } = await this.target(opts);

    // Candidate = tree: the shipped inputs being released are the ones the candidate was built from.
    try {
      await run("git", ["diff", "--quiet", candidate.source, "HEAD", "--", ...LINES[this.pkg.name].inputs], { cwd });
    } catch {
      throw new Error(`${this.pkg.name}: ${LINES[this.pkg.name].inputs.join(", ")} changed since the candidate was built (${candidate.source}). The next release run builds a new candidate.`);
    }

    await run("docker", ["buildx", "imagetools", "create", ...tags.flatMap((tag) => ["--tag", tag]), candidate.image]);

    // Published = candidate.
    for (const tag of tags) {
      const published = await remoteDigest(tag);
      if (published !== digest) throw new Error(`${tag} resolves to ${published ?? "nothing"}, expected ${digest}`);
    }
    return { type: "published" };
  }

  async status(opts: PublishTaskContext): Promise<"done" | "pending"> {
    const { digest, tags } = await this.target(opts);
    return (await remoteDigest(tags[0])) === digest ? "done" : "pending";
  }
}

/**
 * Ties the release lines to their images:
 * - a base release also releases ext (built on it), with the base's changelog entries,
 * - versioning records the candidate each bumped line will ship (`releases/<line>/CANDIDATE`) and adds its
 *   package diff to the changelog; it refuses to version without a candidate,
 * - publishing promotes the candidate's digest to the release tags.
 *
 * Inputs come from the release workflow: `HIPPO_CANDIDATES` (a directory with one CANDIDATE file per line)
 * and `HIPPO_PACKAGE_DIFFS` (a directory with an optional `<line>.md` per line).
 */
export function images(): TegamiPlugin {
  return {
    name: "images",
    initDraft(draft) {
      const graph = this.graph;
      draft.addPolicy({
        id: "images:ext-follows-base",
        onUpdate({ pkg, packageDraft }) {
          if (pkg.name !== BASE || !packageDraft.type) return;
          for (const ext of graph.getByName(EXT)) this.bumpPackage(ext, { type: packageDraft.type, reason: `built on ${BASE}` });
        },
      });
    },
    async applyDraft(draft) {
      const bumped = this.graph
        .getPackages()
        .filter((pkg): pkg is ReleasePackage => pkg instanceof ReleasePackage && Boolean(draft.getPackageDraft(pkg.id)?.type));

      const base = bumped.find((pkg) => pkg.name === BASE);
      const ext = bumped.find((pkg) => pkg.name === EXT);
      if (base && ext) {
        const extDraft = draft.getPackageDraft(ext.id)!;
        for (const entry of draft.getPackageDraft(base.id)?.changelogs ?? []) {
          if (!extDraft.changelogs?.some((item) => item.id === entry.id)) (extDraft.changelogs ??= []).push(entry);
        }
      }

      const candidates = process.env.HIPPO_CANDIDATES;
      if (bumped.length > 0 && !candidates) {
        throw new Error("[images] versioning needs candidate images (HIPPO_CANDIDATES); it runs in the release workflow.");
      }
      for (const pkg of bumped) {
        await copyFile(path.join(candidates!, pkg.name), path.join(pkg.path, "CANDIDATE")).catch(() => {
          throw new Error(`[images] no candidate for ${pkg.name} in ${candidates}`);
        });
        const diff = process.env.HIPPO_PACKAGE_DIFFS
          ? await readFile(path.join(process.env.HIPPO_PACKAGE_DIFFS, `${pkg.name}.md`), "utf8").catch(() => "")
          : "";
        if (diff.trim()) (draft.getPackageDraft(pkg.id)!.changelogs ??= []).push(virtualEntry(pkg.name, "Package changes", diff.trim()));
      }
    },
    publishPreflight({ pkg }) {
      if (pkg instanceof ReleasePackage) return { shouldPublish: true };
    },
    publishTasks({ plan }) {
      return plan.getPackagesToPublish().map((pkg) => pkg instanceof ReleasePackage && new ImagePromoteTask(pkg));
    },
  };
}
