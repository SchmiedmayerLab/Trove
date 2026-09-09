"""Check the locked validator digest against the official GitHub release asset."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

from dataclasses import dataclass
import json
from pathlib import Path
import re
import subprocess
import sys


@dataclass(frozen=True)
class ValidatorPin:
    version: str
    digest: str

    @classmethod
    def from_manifest(cls, value: object) -> "ValidatorPin":
        if not isinstance(value, dict):
            raise ValueError("Invalid validator manifest")
        version, digest = value.get("validatorVersion"), value.get("validatorSHA256")
        if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
            raise ValueError("Invalid validator version")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("Invalid validator checksum")
        return cls(version, digest)

    @property
    def release_api(self) -> str:
        return "repos/hapifhir/org.hl7.fhir.core/releases/tags/" + self.version

    def verify_release(self, value: object) -> None:
        if not isinstance(value, dict) or value.get("tag_name") != self.version:
            raise ValueError("Official release does not match the locked version")
        if value.get("draft") is not False or value.get("prerelease") is not False:
            raise ValueError("Expected a published stable validator release")
        assets = value.get("assets")
        if not isinstance(assets, list) or not all(isinstance(asset, dict) for asset in assets):
            raise ValueError("Invalid official release asset inventory")
        matches = [asset for asset in assets if asset.get("name") == "validator_cli.jar"]
        if len(matches) != 1:
            raise ValueError("Expected exactly one official validator_cli.jar asset")
        if matches[0].get("digest") != "sha256:" + self.digest:
            raise ValueError("Official validator asset does not match the locked checksum; investigate before repinning")


def main() -> None:
    pin = ValidatorPin.from_manifest(json.loads(Path(__file__).with_name("manifest.json").read_bytes()))
    # gh owns authentication. Never print credentials or execute a shell assembled from metadata.
    release = subprocess.run(["gh", "api", pin.release_api], check=True, capture_output=True, timeout=30)
    pin.verify_release(json.loads(release.stdout))
    print(f"Validator {pin.version}: official release asset matches sha256:{pin.digest}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        message = str(error) if isinstance(error, ValueError) else "Official release lookup failed; pin remains unverified"
        print(message, file=sys.stderr)
        sys.exit(1)
