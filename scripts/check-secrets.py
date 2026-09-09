#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Scan publishable working-tree files, with redaction and an executable negative control."""

import argparse
import base64
from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


VERSION = "8.30.1"
ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class SourceFile:
    path: str
    sha256: str


@dataclass(frozen=True)
class Finding:
    rule: str
    file: str
    line: int


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def publication_files(root: Path) -> list[Path]:
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        capture_output=True, check=True, timeout=30,
    )
    names = sorted(set(name.decode("utf-8") for name in result.stdout.split(b"\0") if name))
    files: list[Path] = []
    for name in names:
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Invalid publication path")
        path = root / relative
        if path.is_symlink() or any(parent.is_symlink() for parent in path.parents if parent != root):
            raise ValueError("Publication scan requires regular files, not symlinks")
        if not path.exists():  # A tracked file deleted in the working tree is not published.
            continue
        if not path.is_file():
            raise ValueError("Publication scan cannot silently omit submodules or nonregular files")
        files.append(relative)
    if not files:
        raise ValueError("Publication scan selected no files")
    return files


def snapshot(root: Path, destination: Path) -> list[SourceFile]:
    inventory: list[SourceFile] = []
    for relative in publication_files(root):
        source = root / relative
        original = digest(source)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        if digest(target) != original or digest(source) != original:
            raise ValueError("Source changed while preparing the scan")
        inventory.append(SourceFile(relative.as_posix(), original))
    return inventory


def verify_unchanged(root: Path, inventory: list[SourceFile]) -> None:
    if [path.as_posix() for path in publication_files(root)] != [entry.path for entry in inventory]:
        raise ValueError("Publication file selection changed during the scan")
    if any(digest(root / entry.path) != entry.sha256 for entry in inventory):
        raise ValueError("Source changed during the scan")


def findings(path: Path, source: Path) -> list[Finding]:
    value: object = json.loads(path.read_text())
    if not isinstance(value, list) or any(not isinstance(entry, dict) for entry in value):
        raise ValueError("Scanner did not produce a findings array")
    result: list[Finding] = []
    for entry in value:
        if not isinstance(entry.get("RuleID"), str) or not entry["RuleID"] or not isinstance(entry.get("File"), str) or not entry["File"]:
            raise ValueError("Scanner finding has no rule or file identity")
        if entry.get("Secret") != "REDACTED":
            raise ValueError("Scanner returned an unredacted finding")
        line = entry.get("StartLine")
        if type(line) is not int or line < 1:
            raise ValueError("Scanner finding has an invalid line")
        relative = Path(entry["File"]).resolve().relative_to(source.resolve())
        if not (source / relative).is_file():
            raise ValueError("Scanner finding does not identify a scanned file")
        result.append(Finding(entry["RuleID"], relative.as_posix(), line))
    return result


def scan(binary: str, source: Path, config: Path, report: Path, work: Path) -> tuple[int, list[Finding]]:
    # No environment-selected config, inline suppression, or fingerprint ignore file.
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GITLEAKS_")}
    result = subprocess.run(
        [binary, "dir", str(source), "--config", str(config), "--ignore-gitleaks-allow",
         "--gitleaks-ignore-path", str(work / "no-fingerprint-ignores"), "--redact=100",
         "--report-format", "json", "--report-path", str(report), "--timeout", "300",
         "--no-banner", "--no-color"],
        env=environment, cwd=work, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        check=False, timeout=330,
    )
    detected = findings(report, source)
    if result.returncode != (1 if detected else 0):
        raise ValueError("Scanner exit status does not match its report")
    return result.returncode, detected


def run(root: Path, output: Path) -> int:
    binary = shutil.which("gitleaks")
    if binary is None:
        raise ValueError("gitleaks is required")
    version = subprocess.run([binary, "version"], capture_output=True, text=True, check=True, timeout=10).stdout.strip()
    if version != VERSION:
        raise ValueError(f"gitleaks {VERSION} is required")
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError("Use an empty output directory for fresh evidence")
    with tempfile.TemporaryDirectory(prefix="trove-secret-scan-") as temporary:
        work = Path(temporary)
        source = work / "source"
        inventory = snapshot(root, source)
        config = source / ".gitleaks.toml"
        if not config.is_file():
            raise ValueError("The reviewed scanner configuration is required")
        # Synthetic format-valid text, never a credential. A skipped/disabled scanner
        # cannot produce a passing run merely by returning an empty findings array.
        probe = work / "probe"
        probe.mkdir()
        token = "ghp_" + hashlib.sha256(b"Trove scanner negative control, not a credential").hexdigest()[:36]
        probe_paths = [
            "control.txt", ".github/workflows/build-and-test.yml",
            "TroveInfrastructure/validator/verify_process_restart.py",
            "TroveInfrastructure/infrastructure/dev/vault-token-secret.yaml",
            "TroveServer/Tests/TroveServerTests/Support/TransportCertificates.swift",
            "TroveServer/Tests/TroveServerTests/Integration/InboundTransportTests.swift",
        ]
        for name in probe_paths:
            target = probe / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(f"token={token}\n")
        (probe / probe_paths[3]).write_text(
            "apiVersion: v1\nkind: Secret\nmetadata:\n  name: negative-control\ndata:\n  token: "
            + base64.b64encode(token.encode()).decode() + "\n"
        )
        probe_status, probe_findings = scan(binary, probe, config, work / "probe.json", work)
        if probe_status != 1 or {finding.file for finding in probe_findings} != set(probe_paths):
            raise ValueError("Scanner failed its executable negative control")
        status, detected = scan(binary, source, config, work / "findings.json", work)
        verify_unchanged(root, inventory)
        # Retain locations only, never raw matched lines, fragments, or credentials.
        (output / "findings.json").write_text(json.dumps([asdict(finding) for finding in detected], indent=2) + "\n")
        (output / "source.json").write_text(json.dumps([asdict(entry) for entry in inventory], indent=2) + "\n")
        (output / "result.json").write_text(json.dumps({
            "scanner": "gitleaks", "version": version, "binarySHA256": digest(Path(binary)),
            "sourceInventorySHA256": digest(output / "source.json"), "fileCount": len(inventory),
            "negativeControlFindings": len(probe_findings), "findings": len(detected),
            "result": "passed" if status == 0 else "failed",
        }, indent=2) + "\n")
        print(f"Secret scan: {len(inventory)} files, {len(detected)} findings; negative control verified")
        return status


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        return run(ROOT.resolve(), arguments.output.resolve())
    except (OSError, ValueError, subprocess.SubprocessError):
        # Exception messages from tools/paths may themselves contain sensitive input.
        print("Secret verification failed; no passing evidence was produced.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
