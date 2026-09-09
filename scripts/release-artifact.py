# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

"""Package and verify tested image archives. This command never pushes or deploys."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
from datetime import datetime, timezone


ROOT = Path(__file__).resolve().parents[1]
COMPONENTS = ("server", "web")
ARCHITECTURES = ("amd64", "arm64")
EVIDENCE = ("result.json", "vulnerabilities.json", "sbom.cdx.json", "database.json")


def command(*arguments: str, cwd: Path | None = None, timeout: int = 60) -> str:
    return subprocess.run(arguments, cwd=cwd, capture_output=True, text=True,
                          check=True, timeout=timeout).stdout.strip()


def digest(path: Path) -> str:
    if not path.is_file() or path.is_symlink() or path.resolve() != path.absolute():
        raise ValueError("Expected a regular artifact file")
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def object_file(path: Path) -> dict[str, object]:
    if not path.is_file() or path.is_symlink() or path.resolve() != path.absolute():
        raise ValueError("Expected a regular artifact file")
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError("Expected a JSON object")
    return value


def sha(value: object, prefix: str = "") -> str:
    if not isinstance(value, str) or re.fullmatch(re.escape(prefix) + r"[0-9a-f]{64}", value) is None:
        raise ValueError("Invalid digest")
    return value


def source_context(root: Path) -> dict[str, object]:
    revision = command("git", "rev-parse", "HEAD", cwd=root)
    if re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise ValueError("Invalid source revision")
    names = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
                           cwd=root, check=True, capture_output=True, timeout=30).stdout.split(b"\0")
    files: dict[str, str] = {}
    for name in sorted(set(names) - {b""}):
        relative = Path(name.decode())
        path = root / relative
        if path.is_symlink() or path.resolve() != path or relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Source inventory requires regular repository files")
        if path.exists():
            files[relative.as_posix()] = digest(path)
    if not files:
        raise ValueError("Source inventory is empty")
    return {"revision": revision, "clean": not command("git", "status", "--porcelain", cwd=root),
            "treeSHA256": hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()}


def archive_identity(path: Path, expected: str) -> None:
    # Docker handles the OCI content graph on import. Inspect, never extract, tar paths here.
    with tarfile.open(path, "r:") as archive:
        entries = [member for member in archive if member.name == "index.json"]
        if len(entries) != 1 or not entries[0].isfile() or entries[0].size > 65536:
            raise ValueError("Expected one bounded OCI archive index")
        stream = archive.extractfile(entries[0])
        if stream is None:
            raise ValueError("Missing OCI index")
        index = json.load(stream)
        if not isinstance(index, dict) or index.get("schemaVersion") != 2:
            raise ValueError("Invalid OCI index")
        descriptors = index.get("manifests")
        if not isinstance(descriptors, list) or len(descriptors) != 1 or not isinstance(descriptors[0], dict):
            raise ValueError("Archive must contain exactly one tested image identity")
        if descriptors[0].get("digest") != expected:
            raise ValueError("Archive does not contain the tested image")


def scan_identity(directory: Path, expected: str, *, fresh: bool = False) -> None:
    result = object_file(directory / "result.json")
    if result.get("result") != "passed" or type(result.get("vulnerabilities")) is not int or result["vulnerabilities"] != 0:
        raise ValueError("Image scan did not pass")
    if result.get("negativeControlPassed") is not True or result.get("image") != expected:
        raise ValueError("Image scan has missing control or mismatched identity")
    for field, filename in (("reportSHA256", "vulnerabilities.json"), ("sbomSHA256", "sbom.cdx.json")):
        if sha(result.get(field)) != digest(directory / filename):
            raise ValueError("Image evidence changed")
    report = object_file(directory / "vulnerabilities.json")
    metadata = report.get("Metadata")
    if not isinstance(metadata, dict) or metadata.get("ImageID") != expected:
        raise ValueError("Underlying scan analyzed another image")
    if fresh:
        database = object_file(directory / "database.json")
        next_update = database.get("NextUpdate")
        if not isinstance(next_update, str):
            raise ValueError("Missing advisory database freshness")
        deadline = datetime.fromisoformat(next_update.replace("Z", "+00:00"))
        if deadline.tzinfo is None or deadline <= datetime.now(timezone.utc):
            raise ValueError("Advisory database expired; rerun verification")


def package(root: Path, component: str, architecture: str, image: str, scans: Path, output: Path) -> None:
    context = source_context(root)
    run, attempt = os.environ.get("GITHUB_RUN_ID"), os.environ.get("GITHUB_RUN_ATTEMPT")
    if os.environ.get("GITHUB_ACTIONS") == "true" and (
        context["clean"] is not True or os.environ.get("GITHUB_SHA") != context["revision"]
        or os.environ.get("GITHUB_REPOSITORY") != "SchmiedmayerLab/Trove"
        or not run or not run.isdecimal() or not attempt or not attempt.isdecimal()
    ):
        raise ValueError("CI artifacts require unchanged, identified source")
    inspected = json.loads(command("docker", "image", "inspect", image))
    if not isinstance(inspected, list) or len(inspected) != 1:
        raise ValueError("Expected one local image")
    info = inspected[0]
    if not isinstance(info, dict) or not isinstance(info.get("Config"), dict):
        raise ValueError("Malformed image metadata")
    identity = sha(info.get("Id"), "sha256:")
    if info.get("Architecture") != architecture or info.get("Os") != "linux":
        raise ValueError("Image platform differs from its verification runner")
    labels = info.get("Config", {}).get("Labels") or {}
    if not isinstance(labels, dict):
        raise ValueError("Malformed image labels")
    if labels.get("org.opencontainers.image.revision") != context["revision"]:
        raise ValueError("Image source label differs from the checkout")
    scan_identity(scans, identity)
    output.mkdir(parents=True, exist_ok=False)
    evidence = output / "scan"
    evidence.mkdir()
    for name in EVIDENCE:
        source = scans / name
        if source.is_symlink() or not source.is_file():
            raise ValueError("Expected regular evidence files")
        shutil.copyfile(source, evidence / name)
    command("docker", "image", "save", "--output", str(output / "image.tar"), image, timeout=300)
    archive_identity(output / "image.tar", identity)
    if source_context(root) != context:
        raise ValueError("Source changed during artifact packaging")
    artifact = {"schemaVersion": 1, "component": component, "architecture": architecture,
                "source": context, "run": run, "attempt": attempt, "image": identity,
                "archiveSHA256": digest(output / "image.tar"),
                "evidence": {name: digest(evidence / name) for name in EVIDENCE}}
    (output / "artifact.json").write_text(json.dumps(artifact, indent=2) + "\n")


def verify(directory: Path, component: str, architecture: str, revision: str, run: str, attempt: str) -> dict[str, object]:
    artifact = object_file(directory / "artifact.json")
    if type(artifact.get("schemaVersion")) is not int or artifact["schemaVersion"] != 1:
        raise ValueError("Unsupported artifact manifest")
    if artifact.get("component") != component or artifact.get("architecture") != architecture:
        raise ValueError("Missing or misplaced component/platform")
    source = artifact.get("source")
    if not isinstance(source, dict) or source.get("clean") is not True or source.get("revision") != revision:
        raise ValueError("Artifacts are not from the clean expected source")
    sha(source.get("treeSHA256"))
    if artifact.get("run") != run or artifact.get("attempt") != attempt:
        raise ValueError("Artifact is not from this verification attempt")
    identity = sha(artifact.get("image"), "sha256:")
    if sha(artifact.get("archiveSHA256")) != digest(directory / "image.tar"):
        raise ValueError("Image archive changed")
    evidence = artifact.get("evidence")
    if not isinstance(evidence, dict) or set(evidence) != set(EVIDENCE):
        raise ValueError("Required image evidence is missing")
    for name in EVIDENCE:
        if sha(evidence[name]) != digest(directory / "scan" / name):
            raise ValueError("Image evidence changed")
    scan_identity(directory / "scan", identity, fresh=True)
    archive_identity(directory / "image.tar", identity)
    return artifact


def verify_set(root: Path, revision: str, run: str, attempt: str) -> dict[str, object]:
    if re.fullmatch(r"[0-9a-f]{40}", revision) is None or not run.isdecimal() or not attempt.isdecimal():
        raise ValueError("Invalid expected workflow identity")
    artifacts = [verify(root / arch / component, component, arch, revision, run, attempt)
                 for arch in ARCHITECTURES for component in COMPONENTS]
    if len({json.dumps(artifact["source"], sort_keys=True) for artifact in artifacts}) != 1:
        raise ValueError("Architectures were built from different source trees")
    return {"sourceRevision": revision, "tag": f"sha-{revision}-{run}-{attempt}",
            "images": {component: {arch: artifacts[index * 2 + COMPONENTS.index(component)]["image"]
                                    for index, arch in enumerate(ARCHITECTURES)} for component in COMPONENTS}}


def approval_environment(path: Path) -> None:
    environment = object_file(path)
    if environment.get("name") != "candidate-publication":
        raise ValueError("Unexpected publication environment")
    rules = environment.get("protection_rules")
    if not isinstance(rules, list) or not any(
        isinstance(rule, dict) and rule.get("type") == "required_reviewers"
        and rule.get("prevent_self_review") is True and isinstance(rule.get("reviewers"), list)
        and len(rule["reviewers"]) > 0 for rule in rules
    ):
        raise ValueError("Independent environment review must be configured")
    policy = environment.get("deployment_branch_policy")
    if not isinstance(policy, dict) or policy.get("protected_branches") is not True:
        raise ValueError("Publication must be restricted to protected branches")


def registry_result(plan: Path, directory: Path) -> dict[str, object]:
    verified = object_file(plan)
    revision = verified.get("sourceRevision")
    if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise ValueError("Invalid verified source revision")
    images = verified.get("images")
    if not isinstance(images, dict) or set(images) != set(COMPONENTS):
        raise ValueError("Missing verified image plan")
    digests: dict[str, str] = {}
    for component in COMPONENTS:
        platforms = images[component]
        if not isinstance(platforms, dict) or set(platforms) != set(ARCHITECTURES):
            raise ValueError("Missing verified image architecture")
        expected: list[object] = []
        for architecture in ARCHITECTURES:
            image = object_file(directory / f"{component}-{architecture}.json")
            if sha(image.get("digest"), "sha256:") != platforms[architecture]:
                raise ValueError("Registry changed an uploaded image digest")
            descriptors = image.get("manifests")
            if not isinstance(descriptors, list) or any(not isinstance(item, dict) for item in descriptors):
                raise ValueError("Missing platform image/provenance descriptors")
            runtime = [item for item in descriptors if isinstance(item.get("platform"), dict)
                       and item["platform"].get("os") == "linux"
                       and item["platform"].get("architecture") == architecture]
            if len(runtime) != 1:
                raise ValueError("Expected one tested runtime platform")
            runtime_digest = sha(runtime[0].get("digest"), "sha256:")
            attestations = [item for item in descriptors if isinstance(item.get("annotations"), dict)
                            and item["annotations"].get("vnd.docker.reference.type") == "attestation-manifest"
                            and item["annotations"].get("vnd.docker.reference.digest") == runtime_digest]
            if len(attestations) != 1 or len(descriptors) != 2:
                raise ValueError("Expected the runtime's preserved build attestation")
            for descriptor in descriptors:
                sha(descriptor.get("digest"), "sha256:")
                if type(descriptor.get("size")) is not int or descriptor["size"] <= 0:
                    raise ValueError("Invalid image descriptor size")
            expected.extend(descriptors)
        merged = object_file(directory / f"{component}.json")
        descriptors = merged.get("manifests")
        if not isinstance(descriptors, list) or sorted(map(lambda item: json.dumps(item, sort_keys=True), descriptors)) != sorted(
            map(lambda item: json.dumps(item, sort_keys=True), expected)
        ):
            raise ValueError("Combined manifest changed the tested image/provenance descriptors")
        digests[component] = sha(merged.get("digest"), "sha256:")
    return {"sourceRevision": revision, "images": digests}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="mode", required=True)
    pack = subcommands.add_parser("package")
    pack.add_argument("--component", choices=COMPONENTS, required=True)
    pack.add_argument("--architecture", choices=ARCHITECTURES, required=True)
    pack.add_argument("--image", required=True)
    pack.add_argument("--scans", type=Path, required=True)
    pack.add_argument("--output", type=Path, required=True)
    check = subcommands.add_parser("verify")
    check.add_argument("--artifacts", type=Path, required=True)
    check.add_argument("--revision", required=True)
    check.add_argument("--run", required=True)
    check.add_argument("--attempt", required=True)
    check.add_argument("--output", type=Path, required=True)
    approval = subcommands.add_parser("approval")
    approval.add_argument("--environment", type=Path, required=True)
    registry = subcommands.add_parser("registry")
    registry.add_argument("--plan", type=Path, required=True)
    registry.add_argument("--directory", type=Path, required=True)
    registry.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.mode == "package":
            package(ROOT.resolve(), args.component, args.architecture, args.image, args.scans.resolve(), args.output.resolve())
        elif args.mode == "approval":
            approval_environment(args.environment.resolve())
        else:
            result = (verify_set(args.artifacts.resolve(), args.revision, args.run, args.attempt)
                      if args.mode == "verify" else registry_result(args.plan.resolve(), args.directory.resolve()))
            # Refuse to overwrite an earlier plan; callers must stop on failure.
            with args.output.open("x") as stream:
                json.dump(result, stream, indent=2)
        return 0
    except (OSError, ValueError, TypeError, tarfile.TarError, subprocess.SubprocessError):
        print("Image artifact verification failed; publication is not authorized.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
