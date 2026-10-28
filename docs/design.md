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
 apps ──► HAProxy (:5000 → primary)          or libpq: host=pg-1,pg-2,pg-3
             │  health check GET :8008/primary     target_session_attrs=read-write
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

- Connect via HAProxy, or via libpq with **`host=pg-1,pg-2,pg-3`**. A single multi-address
  name (`host=pg`) does *not* work with `target_session_attrs`.
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
  smoke/                  3-node Swarm smoke test, grown out of lab/
releases/hippo/
  VERSION                 current release version (semver, ours)
  CHANGELOG.md            release notes, written by Tegami
  CANDIDATE               source commit + digests of the images the pending release ships
.tegami/                  pending changelog entries (Tegami's location)
scripts/                  Tegami config + plugins, release scripts (as in botkit)
docs/                     design + user docs
lab/                      experiments, never shipped
renovate.json, package.json, pnpm-lock.yaml   repo-level config; Node is release tooling only
```

Layout rules:

- **One image = one folder under `images/`**, containing its Dockerfile and every pin that
  feeds it; the folder is the build context. Adding a variant means adding a folder.
- **Shipped content is exactly `images/` and `deploy/`.** The images are a function of
  `images/` alone; the release's stack asset is rendered from `deploy/`. Everything else is
  tooling, tests or documentation.

## Dependency updates

| Dependency | Pinned in | Renovate datasource | Cooldown | Automerge |
|---|---|---|---|---|
| `postgres:18` base image | `images/base/Dockerfile`, tag + digest | `docker` (Docker Hub) | yes | patch / digest |
| Patroni + Python deps | `images/base/requirements.lock` | `pypi` | yes | patch |
| PGDG extensions | `images/ext/extensions.yaml` | `deb` (custom regex manager) | no timestamps → weekly grouped PR | `upgrade: plain` only |
| etcd, HAProxy (reference stack) | `deploy/stack.yml`, tag + digest | `github-releases` / `docker` | yes | patch |
| GitHub Actions | workflows, SHA-pinned | `github-actions` | yes | yes |
| Tegami | `package.json` lockfile | `npm` | yes | **no** (young, plugin API undocumented) |

- Extension bumps with `upgrade: alter` (need `ALTER EXTENSION … UPDATE`) get a separate,
  manually reviewed PR until in-image upgrade logic exists.
- Every Renovate PR runs the normal CI: build, then the 3-node Swarm smoke test
  (bootstrap, forced rolling restart under writes, no lost commits, templated-hostname
  DNS still resolves).

## Release pipeline

Releases are managed by [Tegami](https://github.com/fuma-nama/tegami) with a single
release line, `hippo`, backed by `releases/hippo/VERSION`. Variants are a build-matrix
concern, not separate release lines: every hippo version ships both variants.

**Versioning** is our own semver, independent of the PostgreSQL version:

- **major**: breaking change to the stack / config contract
- **minor**: new extension or feature, Patroni minor
- **patch**: dependency bumps, including PG 18.x minors

**Tags** per release, e.g. `1.4.2`:

| Tag | Moves? | Variant |
|---|---|---|
| `18-1.4.2` / `18-1.4.2-ext` | no (immutable) | base / ext |
| `18` / `18-ext` | yes | base / ext |
| `candidate-<sha>` / `candidate-<sha>-ext` | no, GHCR only, pruned | pending release |

Docker Hub only ever receives released images; candidates stay on GHCR.

### Flow

```
push to main
  └ release workflow (serialized: one run at a time, never cancelled)
     1. build base from HEAD → push candidate-<sha>
        build ext FROM that base digest → push candidate-<sha>-ext
     2. verify + smoke-test the candidates (see invariants)
     3. tegami version → open / regenerate the Version PR containing:
          VERSION       bumped
          CHANGELOG.md  the PRs' .tegami entries + the derived package diff
          CANDIDATE     source commit + both candidate digests

merge the Version PR (manual for now)
  └ release workflow → tegami publish
     1. check the candidate still matches the tree being released
     2. promote: copy the candidate digests to the release tags on GHCR + Docker Hub
     3. check every published tag resolves to the CANDIDATE digests
     4. git tag hippo@<version> + GitHub release (only now, so it never points at nothing)
        release assets: rendered stack.yml with the release digests, package manifest
```

The candidate is built in the push-to-main run rather than in the Version PR's own CI
because PRs created with `GITHUB_TOKEN` do not trigger workflows. It also needs no
special token: the run that writes the Version PR has already built and tested what it
describes.

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
6. **Nothing version-specific inside the image.** The image is a function of `images/`
   only, so `VERSION` / `CHANGELOG.md` / `CANDIDATE` changes never change a digest.

### Invariants (the only checks)

Four general checks, each enforcing one rule above. Any failure stops the run, and the
next push regenerates everything.

| Check | When | Asserts |
|---|---|---|
| **Change = entry** | every PR | a PR touching shipped content (`images/`, `deploy/`) contains a `.tegami/` entry |
| **Pins = contents** | every build | the packages installed in the image (`dpkg-query`, `pip freeze`) match the pin files exactly |
| **Candidate = tree** | before promotion | `git diff --quiet <CANDIDATE.source> HEAD -- images/ deploy/`: the shipped content being released is what the candidate was built from |
| **Published = candidate** | after promotion | every release tag on both registries resolves to the `CANDIDATE` digests |

The "candidate = tree" check also covers the race where `main` moves while a Version PR is
open: the newer push has regenerated the PR anyway, and merging a stale one fails closed
instead of shipping the wrong image.

### Changelog entries for Renovate PRs

Renovate PRs get their entry the same way as in botkit: a workflow on the PR writes
`.tegami/<branch-slug>.md` from the PR's title (and the `upstream` link from
`images/ext/extensions.yaml` for extension bumps), and the `fixer` GitHub App pushes it to the PR
branch. This keeps working without special cases because:

- **The entry is a pure function of the PR.** File name from the branch, content from the
  title. Every sync regenerates it, so when Renovate retargets a PR to a newer version the
  entry follows, and re-running the workflow is a no-op.
- **Renovate keeps owning its branch.** The fixer App is in Renovate's `gitIgnoredAuthors`,
  so its commit does not stop Renovate from rebasing. A rebase drops the entry commit, and
  the next sync writes it again.
- **The bump level comes from Renovate.** Renovate labels each PR with its update type, and
  the workflow maps that to the entry's bump (patch by default, minor for e.g. a Patroni
  minor).

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
8. Inject the derived package diff into the new version's changelog during `tegami
   version` (plugin `applyDraft` hook, unverified), or as a post-processing step on
   `CHANGELOG.md`.
9. Auto-merging the Version PR. Manual for now; later tooling (needs an App token so the
   PR's checks run).
10. OS-only updates (no pin changed, but Debian packages did): need a trigger, e.g. a
    weekly `apt list --upgradable` check against the last release. Deferred.
11. Retention policy for `candidate-*` tags on GHCR.
12. Documentation site: build `docs/` with [Zensical](https://zensical.org) later. For now
    the docs are plain Markdown in the repo.
