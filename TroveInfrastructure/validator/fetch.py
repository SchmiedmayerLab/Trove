"""Fetch the manifest's public artifacts before offline context preparation."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent


def artifacts(manifest):
    yield ("validator_cli.jar", manifest["validatorSHA256"],
           "https://github.com/hapifhir/org.hl7.fhir.core/releases/download/"
           f'{manifest["validatorVersion"]}/validator_cli.jar')
    for package in manifest["bootstrap"]:
        name, version = re.split(r"-(?=\d)", package["file"].removesuffix(".tgz"), maxsplit=1)
        yield ("packages/" + package["file"], package["sha256"],
               f"https://packages.fhir.org/{name}/{version}")
    release = manifest["guideRelease"]
    for package in manifest["guides"]:
        yield ("packages/" + package["file"], package["sha256"],
               f'https://github.com/{release["repository"]}/releases/download/'
               f'{release["tag"]}/{package["packageId"]}-{release["tag"]}.tgz')


def fetch(manifest, output):
    output.mkdir(parents=True, exist_ok=True)
    for name, checksum, url in artifacts(manifest):
        destination = output / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            if destination.is_symlink() or not destination.is_file():
                raise ValueError("Invalid artifact cache entry: " + name)
            with destination.open("rb") as stream:
                if hashlib.file_digest(stream, "sha256").hexdigest() != checksum:
                    raise ValueError("Cached artifact checksum mismatch: " + name)
            continue
        subprocess.run([
            "curl", "--fail", "--location", "--silent", "--show-error",
            "--proto", "=https", "--proto-redir", "=https", "--retry", "3",
            "--connect-timeout", "30", "--max-time", "300",
            "--max-filesize", "536870912", "--output", str(destination), url,
        ], check=True)
        with destination.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != checksum:
                raise ValueError("Pinned artifact checksum mismatch: " + name)
        print("Verified " + name, flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="Artifact directory; existing entries must match their pins.")
    args = parser.parse_args()
    fetch(json.loads((HERE / "manifest.json").read_bytes()), args.output)
