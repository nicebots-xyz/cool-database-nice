"""Pins = contents: checks that an image contains exactly what its pin files declare.

usage: python3 tests/pins/check.py <base|ext> <image>

- base: the Python packages in the Patroni venv are exactly the ones in images/base/requirements.lock.
- ext:  the same, plus every package in images/ext/extensions.yaml is installed at its pinned version.
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOCK_LINE = re.compile(r"^([A-Za-z0-9._-]+)==([^\s;\\]+)")
# Installed by the venv itself, not by the lock.
VENV_BOOTSTRAP = {"pip"}


def normalize(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def manifest(image: str) -> dict[str, dict[str, str]]:
    out = subprocess.run(["docker", "run", "--rm", image, "hippo-manifest"], check=True, capture_output=True, text=True).stdout
    kinds: dict[str, dict[str, str]] = {"deb": {}, "pip": {}}
    for line in out.splitlines():
        kind, name, version = line.split(" ", 2)
        kinds[kind][normalize(name) if kind == "pip" else name] = version
    return kinds


def lock_pins() -> dict[str, str]:
    pins = {}
    for line in (ROOT / "images/base/requirements.lock").read_text().splitlines():
        if match := LOCK_LINE.match(line):
            pins[normalize(match[1])] = match[2]
    return pins


def extension_pins() -> dict[str, str]:
    # extensions.yaml is a flat, fixed-order file (see its header); no YAML library needed.
    pins, package = {}, None
    for line in (ROOT / "images/ext/extensions.yaml").read_text().splitlines():
        key, _, value = line.strip().partition(": ")
        if key == "package":
            package = value
        elif key == "version" and package:
            pins[package], package = value, None
    return pins


def compare(kind: str, pinned: dict[str, str], installed: dict[str, str], exact: bool) -> list[str]:
    errors = [
        f"{kind} {name}: pinned {version}, installed {installed.get(name, 'nothing')}"
        for name, version in sorted(pinned.items())
        if installed.get(name) != version
    ]
    if exact:
        errors += [f"{kind} {name} {installed[name]}: installed but not pinned" for name in sorted(installed.keys() - pinned.keys())]
    return errors


def main() -> int:
    variant, image = sys.argv[1:3]
    if variant not in ("base", "ext"):
        sys.exit("variant must be base or ext")
    contents = manifest(image)
    pip = {name: version for name, version in contents["pip"].items() if name not in VENV_BOOTSTRAP}
    errors = compare("pip", lock_pins(), pip, exact=True)
    if variant == "ext":
        pins = extension_pins()
        if not pins:
            errors.append("images/ext/extensions.yaml declares no packages")
        errors += compare("deb", pins, contents["deb"], exact=False)
    for error in errors:
        print(f"pins: {error}")
    print(f"pins: {image} ({variant}) {'FAILS' if errors else 'matches'} its pin files")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
