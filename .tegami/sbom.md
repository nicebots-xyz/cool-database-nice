---
packages:
  hippo: patch
---

### SBOM covering everything in the images

Images are published with SPDX SBOM and build provenance attestations. The SBOM lists every package and every component no package manager owns (gosu, the postgres entrypoint scripts, hippo's own tooling), each with its license, and releases are refused when anything in the image is missing from it. See `docs/licenses.md`.
