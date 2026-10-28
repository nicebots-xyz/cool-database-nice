<!--
SPDX-License-Identifier: MIT
Copyright: 2026 NiceBots.xyz
-->
# Licenses

## hippo itself

The code in this repository (build definitions, stack files, scripts, tests) is MIT licensed, see
[`LICENSE`](../LICENSE). Every source file carries an SPDX header, checked in CI by
[licensor](https://github.com/nicebots-xyz/licensor).

## What the images contain

The images bundle third-party software under its own licenses: PostgreSQL (PostgreSQL License), Patroni
(MIT), the Debian packages of the base system and the PGDG extensions, Python packages, and a few components
from the official `postgres` image. The reference stack also runs etcd (Apache-2.0) and HAProxy (GPL-2.0)
as their unmodified upstream images.

**Every published image has an SBOM listing all of it, each with its license.** It is attached to the image
as an SPDX attestation, together with build provenance:

```sh
docker buildx imagetools inspect ghcr.io/nicebots-xyz/hippo:18 --format '{{ json .SBOM }}'
docker buildx imagetools inspect ghcr.io/nicebots-xyz/hippo:18 --format '{{ json .Provenance }}'
```

"All of it" is enforced, not hoped for: before anything is released, `tests/sbom/check.py` checks the SBOM
attached to the candidate image, and fails when

- a file in the image is neither owned by a deb or pip package nor declared in
  [`images/base/hippo/components.yaml`](../images/base/hippo/components.yaml) (software that no package
  manager owns, with its license, or generated state),
- an installed package or a declared component is missing from the SBOM,
- a package in the SBOM has no license.

## Full license texts

Inside an image:

| Software | License text |
|---|---|
| Debian packages, incl. PostgreSQL and the extensions | `/usr/share/doc/<package>/copyright` |
| Python packages (Patroni and its dependencies) | `/opt/patroni/lib/python3.13/site-packages/<package>.dist-info/` |
| Declared components | linked from [`components.yaml`](../images/base/hippo/components.yaml) (`source`) |
