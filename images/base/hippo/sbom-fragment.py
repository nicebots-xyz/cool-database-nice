# SPDX-License-Identifier: MIT
# Copyright: 2026 NiceBots.xyz
"""Prints an SPDX document for the components declared in a components file (see components.yaml).

Baked into the image under /usr/share/hippo/sbom/, where the SBOM scanner merges it, so the image's SBOM also
lists the software that no package manager owns, with its license.

usage: python sbom-fragment.py <components.yaml> <name>
"""

import json
import re
import sys

import yaml

path, name = sys.argv[1:3]
components = yaml.safe_load(open(path)).get("components") or []


def slug(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9.-]+", "-", text).strip("-")


packages = []
for component in components:
    purl = component.get("purl") or f"pkg:generic/{slug(component['name'])}"
    package = {
        "name": component["name"],
        "SPDXID": f"SPDXRef-Package-{slug(component['name'])}",
        "downloadLocation": component.get("source", "NOASSERTION"),
        "licenseConcluded": component["license"],
        "licenseDeclared": component["license"],
        "filesAnalyzed": False,
        "externalRefs": [{"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl", "referenceLocator": purl}],
    }
    notes = [component["comment"]] if component.get("comment") else []
    if component.get("paths"):
        notes.append("files: " + ", ".join(component["paths"]))
    if notes:
        package["comment"] = "; ".join(notes)
    packages.append(package)

json.dump(
    {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"hippo-{name}-components",
        "documentNamespace": f"https://github.com/nicebots-xyz/hippo/sbom/{name}-components",
        # Fixed, so the fragment only changes when the declarations do.
        "creationInfo": {"created": "1970-01-01T00:00:00Z", "creators": ["Tool: hippo sbom-fragment"]},
        "packages": packages,
    },
    sys.stdout,
    indent=2,
)
print()
