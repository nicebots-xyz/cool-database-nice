# SPDX-License-Identifier: MIT
# Copyright: 2026 NiceBots.xyz
"""SBOM = contents: checks that an image's SBOM covers everything bundled in it, each with a license.

usage: python3 tests/sbom/check.py <image> <sbom.json>

The SBOM is an SPDX JSON document, bare or wrapped (in-toto attestation, `imagetools inspect` output).
- Every file in the image is owned by a deb or pip package, or declared (images/*/hippo/components.yaml):
  as a component, or as generated state. Declarations that match nothing are errors too.
- Every installed deb and pip package is in the SBOM, and so is every declared component.
- Every package in the SBOM has a license, or a declared component supplies it (by purl).
"""

import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
NO_LICENSE = (None, "", "NOASSERTION", "NONE")


def spdx(document: dict) -> dict:
    """Unwraps an SPDX document from an in-toto statement or `imagetools inspect --format '{{json .SBOM}}'`."""
    for _ in range(3):
        if "packages" in document:
            return document
        document = document.get("predicate") or document.get("SPDX") or document.get("linux/amd64") or {}
    raise SystemExit("sbom: no SPDX document found")


def purl_of(package: dict) -> str:
    return next((r["referenceLocator"] for r in package.get("externalRefs", []) if r.get("referenceType") == "purl"), "")


def purl_base(purl: str) -> str:
    """`pkg:golang/github.com/tianon/gosu@v1.19.0?…` → `pkg:golang/github.com/tianon/gosu`."""
    return re.split(r"[@?#]", purl, maxsplit=1)[0]


def normalize(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def main() -> int:
    image, sbom_file = sys.argv[1:3]
    inventory = json.loads(subprocess.run(
        ["docker", "run", "--rm", "-i", "-u", "root", "--entrypoint", "/opt/patroni/bin/python", image, "-"],
        input=(HERE / "inventory.py").read_text(), capture_output=True, text=True, check=True,
    ).stdout)
    document = spdx(json.load(open(sbom_file)))
    # The document's subject (the image itself) is not something bundled in it.
    subjects = set(document.get("documentDescribes") or []) | {
        r["relatedSpdxElement"] for r in document.get("relationships", [])
        if r.get("spdxElementId") == "SPDXRef-DOCUMENT" and r.get("relationshipType") == "DESCRIBES"
    }
    packages = [package for package in document["packages"] if package["SPDXID"] not in subjects]

    errors = [f"file not owned by any package nor declared: {path}" for path in inventory["undeclared"]]
    errors += [f"declaration matches nothing: {stale}" for stale in inventory["stale"]]

    supplied = {component["purl"] for component in inventory["components"] if component.get("purl")}
    for package in packages:
        licensed = package.get("licenseConcluded") not in NO_LICENSE or package.get("licenseDeclared") not in NO_LICENSE
        if not licensed and purl_base(purl_of(package)) not in supplied:
            errors.append(f"no license in the SBOM: {package['name']} {package.get('versionInfo', '')} ({purl_of(package) or 'no purl'})")
    bases = {purl_base(purl_of(package)) for package in packages}
    errors += [f"declared license for {purl}, which the SBOM does not contain" for purl in sorted(supplied - bases)]

    names = {package["name"] for package in packages if package.get("licenseDeclared") not in NO_LICENSE}
    errors += [f"declared component missing from the SBOM: {c['name']}" for c in inventory["components"] if c["name"] not in names]

    in_sbom = {(purl_of(p).split("/")[0], normalize(p["name"]) if purl_of(p).startswith("pkg:pypi") else p["name"], p.get("versionInfo")) for p in packages}
    for kind, purl_type in (("deb", "pkg:deb"), ("pip", "pkg:pypi")):
        for name, version in sorted(inventory["packages"][kind].items()):
            if (purl_type, name, version) not in in_sbom:
                errors.append(f"{kind} package missing from the SBOM: {name} {version}")

    for error in errors:
        print(f"sbom: {error}")
    counts = {k: len(v) for k, v in inventory["packages"].items()}
    print(f"sbom: {image}: {len(packages)} SBOM packages, {counts['deb']} deb, {counts['pip']} pip, "
          f"{len(inventory['components'])} declared components: {'FAILS' if errors else 'covers everything, all licensed'}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
