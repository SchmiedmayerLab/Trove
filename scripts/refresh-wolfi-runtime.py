#!/usr/bin/env python3
# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT
"""Refresh the Wolfi base digest and the validator runtime package pins.

`versions` runs on each architecture and lists the available versions of the pinned
packages in the given base image. `apply` moves the server and validator runtimes to that
base and each pinned package to its newest version available on every architecture.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASE = "cgr.dev/chainguard/wolfi-base:latest"
BASE_PATTERN = re.compile(re.escape(BASE) + r"@sha256:[0-9a-f]{64}")
SERVER = Path("TroveServer/Dockerfile")
RUNTIME = Path("TroveInfrastructure/validator/runtime/Dockerfile")
MANIFEST = Path("TroveInfrastructure/validator/manifest.json")
PIN_PATTERN = re.compile(r"^(\s+)([a-z0-9][a-z0-9.+_-]*)=(\S+)( \\)?$", re.MULTILINE)


def pins(text):
    """Return the package pins of the runtime Dockerfile, keyed by package name in file order."""
    return {name: version for _, name, version, _ in PIN_PATTERN.findall(text)}


def parse_policy(output):
    """Map each package of `apk policy` output to its versions, oldest first."""
    versions, current = {}, None
    for line in output.splitlines():
        if match := re.fullmatch(r"(\S+) policy:", line):
            current = versions.setdefault(match.group(1), [])
        elif current is not None and (match := re.fullmatch(r"  (\S+):", line)):
            current.append(match.group(1))
    return versions


def newest_common(name, current, architectures):
    """Return the newest version listed for every architecture, using the first one's order.

    The current pin must be listed and must not be newer than the result, so an index in an
    unexpected order fails instead of downgrading the pin.
    """
    first, *others = architectures
    listed = first.get(name, [])
    for version in reversed(listed):
        if all(version in other.get(name, []) for other in others):
            if current not in listed or listed.index(current) > listed.index(version):
                raise ValueError(f"The current {name} pin {current} is not older than {version}")
            return version
    raise ValueError(f"No version of {name} is available on every architecture")


def refresh(root, digest, architectures):
    """Rewrite the pins under root and return the changes as (subject, old, new) tuples."""
    if re.fullmatch(r"sha256:[0-9a-f]{64}", digest) is None:
        raise ValueError("Expected a sha256 image digest")
    base = f"{BASE}@{digest}"
    runtime = (root / RUNTIME).read_text()
    old_pins = pins(runtime)
    new_pins = {name: newest_common(name, old_pins[name], architectures) for name in old_pins}
    changes = []
    for path in (SERVER, RUNTIME):
        match = BASE_PATTERN.search((root / path).read_text())
        if match is None:
            raise ValueError(f"{path} has no digest-pinned {BASE}")
        old_base = match.group(0)
        if old_base != base:
            changes.append((f"wolfi-base in {path}", old_base.split("@")[1], digest))
    changes += [(name, old_pins[name], new_pins[name]) for name in old_pins if old_pins[name] != new_pins[name]]
    for path in (SERVER, RUNTIME):
        text = BASE_PATTERN.sub(base, (root / path).read_text())
        if path == RUNTIME:
            text = PIN_PATTERN.sub(lambda m: f"{m[1]}{m[2]}={new_pins[m[2]]}{m[4] or ''}", text)
        (root / path).write_text(text)
    manifest = json.loads((root / MANIFEST).read_text())
    manifest["runtimeImages"] = {"base": base, "packages": [f"{name}={new_pins[name]}" for name in old_pins]}
    (root / MANIFEST).write_text(json.dumps(manifest, indent=2) + "\n")
    return changes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    versions = commands.add_parser("versions", help="List the available versions of the pinned packages.")
    versions.add_argument("--image", required=True, help="Digest-pinned base image to query.")
    apply = commands.add_parser("apply", help="Rewrite the base digest and package pins.")
    apply.add_argument("--digest", required=True)
    apply.add_argument("versions", nargs="+", type=Path, help="One `versions` output per architecture.")
    arguments = parser.parse_args()
    if arguments.command == "versions":
        names = list(pins((ROOT / RUNTIME).read_text()))
        script = "apk update -q >/dev/null && apk policy " + " ".join(names)
        result = subprocess.run(["docker", "run", "--rm", arguments.image, "sh", "-c", script],
                                capture_output=True, text=True, check=True, timeout=300)
        json.dump(parse_policy(result.stdout), sys.stdout, indent=2)
        print()
    else:
        architectures = [json.loads(path.read_text()) for path in arguments.versions]
        for subject, old, new in refresh(ROOT, arguments.digest, architectures):
            print(f"- `{subject}`: `{old}` to `{new}`")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.SubprocessError, OSError) as error:
        print(f"Wolfi runtime refresh failed: {error}", file=sys.stderr)
        sys.exit(1)
