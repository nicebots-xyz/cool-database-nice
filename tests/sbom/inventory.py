# SPDX-License-Identifier: MIT
# Copyright: 2026 NiceBots.xyz
"""Runs inside a hippo image (fed to its Python on stdin by check.py) and prints a JSON inventory:

- the files no package manager owns that its declarations (/usr/local/lib/hippo/components/*.yaml) do not
  cover either, and the declarations that match no file,
- the declared components,
- the installed deb and pip packages.
"""

import glob
import json
import os
import re
import subprocess
from importlib import metadata

import yaml

# Present in a running container, not in the image.
RUNTIME = {"/.dockerenv"}
SKIP = ("/proc", "/sys", "/dev")


def real(path: str) -> str:
    """The path with its directories resolved (merged /usr: /bin/x is /usr/bin/x), the file itself kept."""
    return os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path))


def owned() -> set[str]:
    paths = set()
    for listing in glob.glob("/var/lib/dpkg/info/*.list"):
        paths.update(real(line.rstrip("\n")) for line in open(listing, errors="replace") if line.strip())
    for record in glob.glob("/opt/patroni/lib/python3*/site-packages/*.dist-info/RECORD"):
        site = os.path.dirname(os.path.dirname(record))
        for line in open(record):
            if entry := line.split(",")[0]:
                paths.add(real(os.path.normpath(os.path.join(site, entry))))
    return paths


def files() -> list[str]:
    found = []
    for root, dirs, names in os.walk("/"):
        dirs[:] = [d for d in dirs if os.path.join(root, d) not in SKIP]
        for name in names:
            path = os.path.join(root, name)
            if os.path.isfile(path) and not os.path.islink(path) and path not in RUNTIME:
                found.append(path)
    return sorted(found)


def pattern(glob_: str) -> re.Pattern:
    regex = re.escape(glob_).replace(r"\*\*", ".*").replace(r"\*", "[^/]*").replace(r"\?", "[^/]")
    return re.compile(f"^{regex}$")


declared = []  # (kind, label, glob)
components = []
for path in sorted(glob.glob("/usr/local/lib/hippo/components/*.yaml")):
    data = yaml.safe_load(open(path)) or {}
    for component in data.get("components") or []:
        components.append(component)
        declared += [("component", component["name"], p) for p in component.get("paths") or []]
    for group in data.get("generated") or []:
        declared += [("generated", group["reason"], p) for p in group["paths"]]

matchers = [(kind, label, glob_, pattern(glob_)) for kind, label, glob_ in declared]
used = set()
undeclared = []
ownership = owned()
for path in files():
    if path in ownership:
        continue
    hit = next((m for m in matchers if m[3].match(path)), None)
    if hit:
        used.add(hit[2])
    else:
        undeclared.append(path)

debs = dict(
    line.split("\t")
    for line in subprocess.run(["dpkg-query", "-W", "-f", "${Package}\t${Version}\n"], capture_output=True, text=True, check=True).stdout.splitlines()
)
pips = {re.sub(r"[-_.]+", "-", d.metadata["Name"]).lower(): d.version for d in metadata.distributions()}

print(json.dumps({
    "undeclared": undeclared,
    "stale": [f"{kind} {label!r}: {glob_}" for kind, label, glob_, _ in matchers if glob_ not in used],
    "components": components,
    "packages": {"deb": debs, "pip": pips},
}))
