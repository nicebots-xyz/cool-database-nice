<!--
SPDX-License-Identifier: MIT
Copyright: 2026 NiceBots.xyz
-->
# Licenses

## hippo

The code in this repository is MIT licensed, see [`LICENSE`](../LICENSE). Source files carry an SPDX
header, checked in CI by [licensor](https://github.com/nicebots-xyz/licensor).

## Image contents

The images bundle third-party software under its own licenses, including PostgreSQL (PostgreSQL License),
Patroni (MIT), Debian packages, the PGDG extensions, Python packages and a few components from the official
`postgres` image. The reference stack also runs etcd (Apache-2.0) and HAProxy (GPL-2.0) from their
unmodified upstream images.

Each published image has an SPDX SBOM attestation listing every package and component with its license,
and a build provenance attestation:

```sh
docker buildx imagetools inspect ghcr.io/nicebots-xyz/hippo:18 --format '{{ json .SBOM }}'
docker buildx imagetools inspect ghcr.io/nicebots-xyz/hippo:18 --format '{{ json .Provenance }}'
```

Software in the image that no package manager owns is declared, with its license, in
[`images/base/hippo/components.yaml`](../images/base/hippo/components.yaml). A release is refused when the
SBOM attached to its image misses a file, package or component, or lists one without a license
(`tests/sbom/check.py`).

## License texts

| Software | Location in the image |
|---|---|
| Debian packages, including PostgreSQL and the extensions | `/usr/share/doc/<package>/copyright` |
| Python packages (Patroni and its dependencies) | `/opt/patroni/lib/python3.13/site-packages/<package>.dist-info/` |
| Declared components | linked from [`components.yaml`](../images/base/hippo/components.yaml) (`source`) |
