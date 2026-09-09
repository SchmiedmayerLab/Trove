# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

"""Verify declared dependencies or an exact local image with the pinned Trivy scanner."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


VERSION = "0.74.0"
ROOT = Path(__file__).resolve().parents[1]
# Recovery uses a nonstandard filename; stage identical bytes under a detected name.
INPUTS = {
    "TroveAPI/Package.resolved": ("TroveAPI/Package.resolved", "swift"),
    "TroveServer/Package.resolved": ("TroveServer/Package.resolved", "swift"),
    "TroveiOS/Trove.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved":
        ("TroveiOS/Package.resolved", "swift"),
    "TroveWeb/package-lock.json": ("TroveWeb/package-lock.json", "npm"),
    "TroveInfrastructure/tools/requirements.txt": ("tools/requirements.txt", "pip"),
    "TroveInfrastructure/validator/recovery-requirements.txt": ("recovery/requirements.txt", "pip"),
}


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inspect_report(path: Path, targets: dict[str, str] | None = None, image: str | None = None) -> int:
    report = json.loads(path.read_text())
    if not isinstance(report, dict) or type(report.get("SchemaVersion")) is not int or report["SchemaVersion"] != 2:
        raise ValueError("Unsupported vulnerability report")
    results = report.get("Results")
    if not isinstance(results, list) or not results:
        raise ValueError("No dependency or OS analysis was performed")
    found: dict[str, str] = {}
    count = 0
    os_analyzed = False
    for result in results:
        if not isinstance(result, dict):
            raise ValueError("Malformed analysis result")
        target, kind = result.get("Target"), result.get("Type")
        if not isinstance(target, str) or not target or not isinstance(kind, str) or not kind or target in found:
            raise ValueError("Missing or repeated analysis identity")
        found[target] = kind
        packages = result.get("Packages")
        if not isinstance(packages, list) or not packages:
            raise ValueError("Analysis has no package inventory")
        for package in packages:
            if not isinstance(package, dict) or any(
                not isinstance(package.get(key), str) or not package[key] for key in ("Name", "Version")
            ):
                raise ValueError("Analysis has incomplete package identities")
        vulnerabilities = result.get("Vulnerabilities", [])
        if not isinstance(vulnerabilities, list):
            raise ValueError("Malformed vulnerability inventory")
        for vulnerability in vulnerabilities:
            if not isinstance(vulnerability, dict) or any(
                not isinstance(vulnerability.get(key), str) or not vulnerability[key]
                for key in ("VulnerabilityID", "PkgName", "Severity")
            ):
                raise ValueError("Malformed vulnerability")
        count += len(vulnerabilities)
        os_analyzed |= result.get("Class") == "os-pkgs"
    if targets is not None and found != targets:
        raise ValueError("Not every declared dependency input was analyzed")
    if image is not None:
        metadata = report.get("Metadata")
        if not isinstance(metadata, dict) or metadata.get("ImageID") != image or not os_analyzed:
            raise ValueError("Image scan did not analyze the exact local image and its OS packages")
    return count


def execute(binary: str, arguments: list[str], work: Path, cache: Path, log: Path) -> int:
    environment = {key: value for key, value in os.environ.items() if not key.startswith("TRIVY_")}
    with log.open("w") as stream:
        result = subprocess.run(
            [binary, *arguments, "--config", str(work / "config.yaml"),
             "--ignorefile", str(work / "ignore"), "--cache-dir", str(cache), "--timeout", "5m"],
            cwd=work, env=environment, stdout=stream, stderr=subprocess.STDOUT, timeout=330, check=False,
        )
    return result.returncode


def verify_status(status: int, count: int) -> None:
    if status != (1 if count else 0):
        raise ValueError("Scanner status does not match its vulnerability report")


def run(root: Path, mode: str, output: Path, cache: Path, image: str | None) -> int:
    binary = shutil.which("trivy")
    if binary is None:
        raise ValueError("Trivy is required")
    version = subprocess.run([binary, "--version"], capture_output=True, text=True, check=True, timeout=10)
    if version.stdout.splitlines()[0] != f"Version: {VERSION}":
        raise ValueError("Use the CI-pinned Trivy version")
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError("Use an empty evidence directory")
    if output == cache or output in cache.parents or cache in output.parents:
        raise ValueError("Keep scanner cache separate from uploaded evidence")
    with tempfile.TemporaryDirectory(prefix="trove-vulnerability-check-") as temporary:
        work = Path(temporary)
        (work / "config.yaml").write_text("{}\n")
        (work / "ignore").write_text("")
        # No package is installed. This known vulnerable requirement must be detected.
        probe = work / "probe"
        probe.mkdir()
        (probe / "requirements.txt").write_text("PyYAML==5.3\n")
        base = ["--scanners", "vuln", "--list-all-pkgs", "--format", "json", "--exit-code", "1"]
        status = execute(binary, ["filesystem", str(probe), *base, "--output", str(output / "control.json")],
                         work, cache, output / "control.log")
        count = inspect_report(output / "control.json", {"requirements.txt": "pip"})
        verify_status(status, count)
        if not count:
            raise ValueError("Vulnerability detection failed its negative control")

        inventory: dict[str, str] = {}
        targets: dict[str, str] | None = None
        identity: str | None = None
        if mode == "dependencies":
            source = work / "source"
            targets = {}
            for original, (relative, kind) in INPUTS.items():
                path = root / original
                if not path.is_file() or path.is_symlink() or path.resolve() != path:
                    raise ValueError("Expected a regular dependency input")
                inventory[original] = digest(path)
                destination = source / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, destination)
                if digest(destination) != inventory[original]:
                    raise ValueError("Dependency input changed during staging")
                targets[relative] = kind
            arguments = ["filesystem", str(source), "--include-dev-deps"]
        else:
            result = subprocess.run(["docker", "image", "inspect", "--format", "{{.Id}}", str(image)],
                                    capture_output=True, text=True, check=True, timeout=30)
            identity = result.stdout.strip()
            if re.fullmatch(r"sha256:[0-9a-f]{64}", identity) is None:
                raise ValueError("Could not resolve one exact local image")
            arguments = ["image", identity, "--image-src", "docker"]
        report = output / "vulnerabilities.json"
        status = execute(binary, [*arguments, *base, "--output", str(report)], work, cache, output / "scan.log")
        count = inspect_report(report, targets, identity)
        verify_status(status, count)
        if any(digest(root / path) != checksum for path, checksum in inventory.items()):
            raise ValueError("Dependency inputs changed during the scan")
        # Conversion inventories the same analyzed packages; it is not another scan.
        if execute(binary, ["convert", str(report), "--format", "cyclonedx", "--output", str(output / "sbom.cdx.json")],
                   work, cache, output / "sbom.log") != 0:
            raise ValueError("SBOM conversion failed")
        sbom = json.loads((output / "sbom.cdx.json").read_text())
        if not isinstance(sbom, dict) or sbom.get("bomFormat") != "CycloneDX" or not sbom.get("components"):
            raise ValueError("SBOM has no component inventory")
        shutil.copyfile(cache / "db/metadata.json", output / "database.json")
        (output / "result.json").write_text(json.dumps({
            "scanner": "trivy", "version": VERSION, "binarySHA256": digest(Path(binary)),
            "inputs": inventory, "image": identity, "vulnerabilities": count,
            "reportSHA256": digest(report), "sbomSHA256": digest(output / "sbom.cdx.json"),
            "negativeControlPassed": True, "result": "failed" if count else "passed",
        }, indent=2) + "\n")
        print(f"Vulnerability check: {mode}, {count} findings; input coverage and negative control verified")
        return status


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("dependencies", "image"))
    parser.add_argument("--image")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    args = parser.parse_args()
    if (args.mode == "image") != (args.image is not None):
        parser.error("--image is required only for image checks")
    try:
        return run(ROOT.resolve(), args.mode, args.output.resolve(), args.cache.resolve(), args.image)
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        print("Vulnerability verification failed; no passing evidence was produced.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
