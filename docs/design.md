<!--
SPDX-License-Identifier: MIT
Copyright: 2026 NiceBots.xyz
-->
# hippo — design overview

## Goal

Highly available PostgreSQL on **Docker Swarm**, built from Patroni + etcd + HAProxy,
shipped as images that **update and release themselves** with no one babysitting them.

Concretely:

- **One `docker stack deploy` is the whole interface.** It must work unchanged from
  Komodo, Portainer or a plain CLI — no external orchestration scripts, no
  "run this before upgrading". Anything cluster-aware lives inside the images.
- **Rolling updates are just Swarm updates.** Swarm restarts one member at a time and
  Patroni turns each leader restart into a clean, fast failover.
- **Dependencies stay current unattended.** Renovate + CI + automerge + automatic
  releases, with cooldowns where the source allows it. Human review only where an
  update genuinely needs a decision.
- **Good Swarm hygiene.** Docker configs and secrets for configuration (versioned,
  immutable); the only volumes are the data directories.
- **Small and boring.** Every extra moving part is a thing that breaks. Features that
  are not needed for the core goal are deferred, not half-built.

### Non-goals (for now)

- PostgreSQL majors other than **18**.
- Supabase-compatible variant, PgBouncer, backups (pgBackRest / WAL-G), ops CLIs,
  stack generators. Backups are the first thing to revisit once the core works.
- Automatic major-version upgrades (`pg_upgrade`). These stay a manual, documented
  procedure.

## Architecture

```
 apps ──► HAProxy (:5000 → primary, :5001 → replicas)      network hippo-clients (attachable)
 ────────────┼──────────────────────────────────────────────────────────────────────────────
             │  health check GET :8008/primary             network hippo (cluster only)
     ┌───────┼────────────┐
   pg-1     pg-2        pg-3      one replicated service `pg` (replicas: 3)
 Patroni   Patroni     Patroni    Patroni runs Postgres; streaming replication
     └───────┬────────────┘
   etcd-1  etcd-2  etcd-3         one replicated service `etcd` (replicas: 3)
```

Both `pg` and `etcd` are **single replicated services**, not one service per member:

| Mechanism | How |
|---|---|
| Stable member identity | `hostname: "pg-{{.Task.Slot}}"` — resolvable on the overlay, follows IP changes |
| Stable data | `volumes: pgdata: name: "pgdata-{{.Task.Slot}}"`, node-local |
| Slots don't wander | `max_replicas_per_node: 1` + exactly N labelled nodes; a lost node's slot stays Pending |
| No VIP | `endpoint_mode: dnsrr` |
| Healthchecks never depend on peers | Swarm publishes a task's DNS names only once it is healthy; a check that needs other members (e.g. etcd quorum) deadlocks bootstrap. etcd has none; Patroni's checks its own Postgres only |
| Safe rollouts | `update_config: {parallelism: 1, order: stop-first}`, `stop_grace_period: 120s` |
| Config | Patroni YAML as a `template_driver: golang` Docker config; passwords via `{{ secret "…" }}` |
| Encrypted traffic | Both overlay networks set `encrypted` (IPsec ESP between nodes) |
| Apps can't touch the cluster | Apps join `hippo-clients`, where only HAProxy is. etcd and Patroni's REST API stay on `hippo`, and Patroni accepts state-changing REST calls from members only (`allowlist_include_members`) |

etcd runs the **stock upstream image**, configured purely through `ETCD_*` env vars with
peer URLs set to the templated hostnames. No custom entrypoint.

### Validated in the lab (2026-10-28)

Docker 29.9.2 dind Swarm, HAProxy 3.2, etcd 3.6.5, Patroni 4.1.5, PG 18.6 — see
[`lab/README.md`](../lab/README.md).

- etcd forced rolling restart: 0/74 failed writes, no membership surgery needed.
- Patroni forced rolling restart under load: worst case 2 failovers, each a sub-second
  to ~4 s window of fast-failing (not hanging) connections; all acknowledged commits
  present, no duplicates.
- HAProxy `server-template` against Docker DNS tracks IP changes with no DNS errors.

### Client rules

- Apps join `hippo-clients` and connect via HAProxy: `haproxy:5000` (primary), `:5001` (replicas).
- Trusted Swarm services can join `hippo` instead and connect via libpq with
  **`host=pg-1,pg-2,pg-3`**, which also reaches etcd. A single multi-address name (`host=pg`)
  does *not* work with `target_session_attrs`.
- During a failover, connections fail fast. Clients should retry with backoff (~10 s) on
  `08xxx`, `57P01`, `25006`; in-flight transactions on the old leader always need an
  app-level retry.
- Deploy images by digest (`image@sha256:…`) so every node runs the same build.

## Image variants (PostgreSQL 18 only)

Base: official `postgres:18` (Debian trixie, from PGDG) + Patroni in a venv. Extensions
come from PGDG apt, pinned to exact versions (apt-archive.postgresql.org keeps every
version, so pins never disappear).

| Variant | Tag | Contents |
|---|---|---|
| **base** | `hippo:18` | PostgreSQL 18 + Patroni + the 46 contrib extensions shipped with Postgres (`pg_stat_statements`, `pgcrypto`, `pg_trgm`, …) |
| **ext** | `hippo:18-ext` | base + a curated set of common, permissively licensed extensions (below) |

Proposed `ext` set (versions as currently in PGDG):

| Extension | PGDG package | Version | Preload? | License |
|---|---|---|---|---|
| pgvector | `postgresql-18-pgvector` | 0.8.7 | no | PostgreSQL |
| pg_cron | `postgresql-18-cron` | 1.6.8 | yes | PostgreSQL |
| pg_partman | `postgresql-18-partman` | 5.5.0 | optional (BGW) | PostgreSQL |
| pgaudit | `postgresql-18-pgaudit` | 18.0 | yes | PostgreSQL |
| pg_repack | `postgresql-18-repack` | 1.5.3 | no | BSD |
| hypopg | `postgresql-18-hypopg` | 1.4.4 | no | PostgreSQL |
| pg_stat_kcache | `postgresql-18-pg-stat-kcache` | 2.3.2 | yes | PostgreSQL |

Extensions are *installed* in the image but only *enabled* by the user
(`shared_preload_libraries` via `patronictl edit-config`, then `CREATE EXTENSION`).

Candidates deliberately left out of the first cut:

- **PostGIS** (`postgresql-18-postgis-3`, 3.6.4) — GPLv2 and a large dependency tree;
  a possible future `geo` variant.
- **TimescaleDB** (`postgresql-18-timescaledb`, 2.31.0+dfsg) — the Debian `+dfsg` build is
  likely the Apache-only edition, without TSL features; needs a licensing decision first.
- **pgvectorscale** — not packaged in PGDG.
- **Supabase-compatible** — deferred; it relies on `docker-entrypoint-initdb.d` scripts,
  which Patroni's own bootstrap bypasses, so it is its own project.

## Repository layout

```
images/
  base/
    Dockerfile            postgres:18 by digest + Patroni
    requirements.lock     Patroni + Python deps, hashed
  ext/
    Dockerfile            FROM the base candidate by digest (build arg) + extensions
    extensions.yaml       extension pins (package, version, upgrade, upstream)
deploy/
  stack.yml               reference stack (etcd, HAProxy pinned; hippo images filled in at release)
tests/
  pins/                   pins = contents check
  sbom/                   SBOM = contents check
  smoke/                  3-node Swarm smoke test, grown out of lab/
releases/<line>/          one per release line: hippo (base image), hippo-ext (ext image)
  VERSION                 current release version (semver, ours)
  CHANGELOG.md            release notes, written by Tegami
  CANDIDATE               source commit + digest of the image the pending release ships
.tegami/                  pending changelog entries (Tegami's location)
scripts/                  Tegami config + plugins, release scripts (as in botkit)
docs/                     design + user docs
lab/                      experiments, never shipped
docker-bake.hcl         the one build definition (ext builds on the base target of the same build)
renovate.json, package.json, pnpm-lock.yaml   repo-level config; Node is release tooling only
```

Layout rules:

- **One image = one folder under `images/`**, containing its Dockerfile and every pin that
  feeds it; the folder is the build context. Adding a variant means adding a folder.
- **Shipped content is exactly `images/`, `deploy/` and `docker-bake.hcl`.** The images are a
  function of `images/` and the build definition; the release's stack asset is rendered from
  `deploy/`. Everything else is tooling, tests or documentation.

## Dependency updates

| Dependency | Pinned in | Renovate datasource | Cooldown | Automerge |
|---|---|---|---|---|
| `postgres:18` base image | `images/base/Dockerfile`, tag + digest | `docker` (Docker Hub) | yes | patch / digest |
| Patroni + Python deps | `images/base/requirements.lock` | `pypi` | yes | patch |
| PGDG extensions | `images/ext/extensions.yaml` | `deb` (custom regex manager) | no timestamps → weekly grouped PR | `upgrade: plain` only |
| etcd, HAProxy (reference stack) | `deploy/stack.yml`, tag | `github-releases` / `docker` | yes | patch |
| GitHub Actions | workflows, SHA-pinned | `github-actions` | yes | yes |
| Tegami | `package.json` lockfile | `npm` | yes | **no** (young, plugin API undocumented) |

- Extension bumps with `upgrade: alter` (need `ALTER EXTENSION … UPDATE`) get a separate,
  manually reviewed PR until in-image upgrade logic exists.
- Every Renovate PR runs the normal CI: build, then the 3-node Swarm smoke test
  (bootstrap, forced rolling restart under writes, no lost commits, templated-hostname
  DNS still resolves).

## Release pipeline

Releases are managed by [Tegami](https://github.com/fuma-nama/tegami) (`scripts/tegami*.mts`) with two
release lines, one per image, so an extension-only change does not release the base image:

| Line | Ships | Built from | Versioned by |
|---|---|---|---|
| `hippo` | base image | `images/base/`, `deploy/`, `docker-bake.hcl` | `releases/hippo/VERSION` |
| `hippo-ext` | ext image | `images/`, `deploy/`, `docker-bake.hcl` (ext is built on base) | `releases/hippo-ext/VERSION` |

**A base release always releases ext too** (Tegami draft policy): same bump type, and ext's changelog
includes the base entries. An entry for `hippo-ext` alone releases only ext.

**Versioning** is our own semver per line, independent of the PostgreSQL version:

- **major**: breaking change to the stack / config contract
- **minor**: new extension or feature, Patroni minor
- **patch**: dependency bumps, including PG 18.x minors

**Tags**, e.g. `hippo@1.4.2` and `hippo-ext@1.5.0`:

| Tag | Moves? | Line |
|---|---|---|
| `18-1.4.2` / `18-ext-1.5.0` | no (immutable) | hippo / hippo-ext |
| `18` / `18-ext` | yes | hippo / hippo-ext |
| `candidate-<sha>` / `candidate-<sha>-ext` | no, GHCR only, pruned | pending release |

All tags live on `ghcr.io/nicebots-xyz/hippo`. Docker Hub (releases only) is on hold until its namespace is
settled.

**Changelogs** (`releases/<line>/CHANGELOG.md`, GitHub releases) use Tegami's default layout, with every entry
linked to its pull request: merges are squash-only, so the commit that added an entry file is its pull
request's squash commit, `… (#N)`.

### Flow

```
push to main
  └ release workflow
     with pending .tegami entries:
       0. wait 15 min; a newer push cancels the wait, so only the last push of a burst builds
       1. build base and ext from HEAD (one bake build, amd64 + arm64) → push candidate-<sha>[-ext]
       2. test the pushed images: pins = contents, SBOM = contents, Swarm smoke test
       3. tegami version (one at a time, skipped once main moved on) → open / regenerate the Version PR; for each bumped line:
            VERSION       bumped
            CHANGELOG.md  the PRs' .tegami entries + the package diff against the line's last release
            CANDIDATE     source commit, PostgreSQL major, candidate digest
     without (the Version PR was merged), right away and one at a time:
       tegami publish, per bumped line:
       1. candidate = tree: the line's inputs are unchanged since CANDIDATE's source commit
       2. promote: point the release tags at the candidate digest (no rebuild)
       3. published = candidate: every release tag resolves to that digest
       4. git tag <line>@<version> + GitHub release, only once the images are published
```

Versioning refuses to run without candidates, so a Version PR always describes tested images. A failed
promotion leaves no tag and no release behind, and re-running a publish is a no-op once the tags point at
the candidate.

Only the wait is ever cancelled: a run past it is never stopped halfway through pushing to GHCR or GitHub. Versioning
and publishing queue apart, so a newer push can only replace a queued run of the same kind, before it started.

The candidate is built in the push-to-main run rather than in the Version PR's own CI because PRs created
with `GITHUB_TOKEN` do not trigger workflows: the run that writes the Version PR has already built and
tested what it describes.

`releases/<line>/CANDIDATE` (`key=value` lines):

```
source=<commit the image was built from>
pg=18
image=ghcr.io/nicebots-xyz/hippo@sha256:…
```

## Drift: design rules

The pipeline mixes generated and human-written content. It stays correct because of how it
is structured, not because of special-case checks. The rules:

1. **One source of truth per fact.** Pins live only in their pin files. Released content
   lives only in registries, addressed by digest. The release version lives only in
   `VERSION`. Everything else is derived from these.
2. **Derived data is never edited; it is regenerated.** The Version PR is a pure function
   of `main` (pending entries + `VERSION` + the current candidate). Each push regenerates
   it from scratch, so a stale or hand-edited Version PR cannot persist. Every workflow is
   idempotent: re-running it gives the same result.
3. **A change's changelog entry lives in the PR that makes the change.** Every PR that
   changes shipped content adds a `.tegami/` entry: written by the author for human PRs,
   generated for Renovate PRs (below). The entry is reviewed and merged together with the
   change, so it describes exactly that change. The only part of the changelog not written
   in a PR is the **package diff** (dpkg manifest of the last released image vs the new
   candidate). No PR causes it; it is a property of the build, so it is derived from the
   build when the Version PR is generated.
4. **Build once, promote bytes.** Images are never rebuilt for a release. The digests you
   reviewed in the Version PR are the ones published, even if Debian or PGDG moved on in
   the meantime. `ext` is built from the base candidate's digest, so it is always exactly
   base plus extensions.
5. **Only one generated commit per release: the Version PR merge.** Releasing never commits
   back to `main`. Rendered artifacts (stack file with digests, manifests) are release
   assets, not files in the repo. Nothing can loop.
6. **Nothing version-specific inside the image.** The image is a function of `images/` and
   `docker-bake.hcl` only, so `VERSION` / `CHANGELOG.md` / `CANDIDATE` changes never change a digest.

### Invariants (the only checks)

Five general checks, each enforcing one rule above. Any failure stops the run, and the
next push regenerates everything.

| Check | When | Asserts |
|---|---|---|
| **Change = entry** | every PR | a PR touching shipped content (`images/`, `deploy/`, `docker-bake.hcl`) contains a `.tegami/` entry |
| **Pins = contents** | every build | the packages installed in the image (`dpkg-query`, `pip freeze`) match the pin files exactly |
| **SBOM = contents** | every build, and the SBOM attached to each candidate | every file is owned by a deb/pip package or declared in `components.yaml`; every package and component is in the SBOM, with a license (see [licenses](licenses.md)) |
| **Candidate = tree** | before promotion | `git diff --quiet <CANDIDATE.source> HEAD -- <the line's inputs>`: the shipped content being released is what the candidate was built from |
| **Published = candidate** | after promotion | every release tag resolves to the `CANDIDATE` digests |

The "candidate = tree" check also covers the race where `main` moves while a Version PR is
open: the newer push has regenerated the PR anyway, and merging a stale one fails closed
instead of shipping the wrong image.

### Changelog entries for Renovate PRs

Renovate PRs get their entry the same way as in botkit: a workflow on the PR writes
`.tegami/<branch-slug>.md` from the PR's title, for the line its files belong to (`hippo-ext` when only
`images/ext/` changed, `hippo` otherwise; none when no shipped content changed) (and the `upstream` link from
`images/ext/extensions.yaml` for extension bumps), and the `fixer` GitHub App pushes it to the PR
branch. This keeps working without special cases because:

- **The entry is a pure function of the PR.** File name from the branch, content from the
  title. Every sync regenerates it, so when Renovate retargets a PR to a newer version the
  entry follows, and re-running the workflow is a no-op.
- **Renovate keeps owning its branch.** The fixer App is in Renovate's `gitIgnoredAuthors`,
  so its commit does not stop Renovate from rebasing. A rebase drops the entry commit, and
  the next sync writes it again.
- **Every dependency update is a patch release**, lock file maintenance included. A reviewer
  can raise the bump in the entry file.

The "change = entry" invariant applies to every PR, human or bot alike.

## Open items

1. Healthcheck should gate on replication lag, not just "Postgres is running".
2. Leader switchover on SIGTERM to an already-updated replica (1 failover per rollout
   instead of up to 2).
3. In-image `ALTER EXTENSION` logic, run by the leader once every member reports the new
   image version. This unlocks fully unattended extension upgrades.
4. Backups (pgBackRest or WAL-G): the first feature after the core.
5. Exact `ext` list sign-off.
6. TimescaleDB licensing: confirm what the PGDG `2.31.0+dfsg` build contains. The guess
   that `+dfsg` means the Apache-only edition (no TSL features) is unverified; decide
   inclusion after that.
7. Preload-only extensions (pg_cron, pgaudit, pg_stat_kcache) only work once listed in
   `shared_preload_libraries`. They ship installed but disabled; document how to enable
   them (`patronictl edit-config` + restart) and decide whether `ext` should preload any
   of them by default.
8. Auto-merging the Version PR. Manual for now; later tooling (needs an App token so the
   PR's checks run).
9. OS-only updates (no pin changed, but Debian packages did): need a trigger, e.g. a
   weekly `apt list --upgradable` check against the last release. Deferred.
10. Retention policy for `candidate-*` tags on GHCR.
11. Documentation site: build `docs/` with [Zensical](https://zensical.org) later. For now
    the docs are plain Markdown in the repo.
12. Release assets: the rendered stack file with release digests, and the package manifest.
