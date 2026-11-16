"""Prepare an offline build context from exact, checksum-locked local artifacts."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import argparse
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

HERE = Path(__file__).resolve().parent


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verified_copy(source, target, expected):
    if source.is_symlink() or not source.is_file() or digest(source) != expected:
        raise ValueError("Pinned artifact missing or checksum mismatch: " + source.name)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)


def unpack_package(archive, cache):
    with tarfile.open(archive, "r:gz") as tar:
        metadata = json.load(tar.extractfile("package/package.json"))
        target = cache / (metadata["name"] + "#" + metadata["version"])
        if target.exists():
            raise ValueError("Duplicate package identity")
        target.mkdir(parents=True)
        tar.extractall(target, filter="data")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--grove-fhir", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path,
                        help="Locked validator_cli.jar and packages/ directory; defaults to the checkout's build outputs.")
    parser.add_argument("--output", type=Path, required=True, help="Must not exist; only this new directory is written.")
    parser.add_argument("--include-lifecycle-corpus", action="store_true",
                        help="Extract the separately pinned receiver test corpus into the context.")
    args = parser.parse_args()
    manifest = json.loads((HERE / "manifest.json").read_bytes())
    args.output.mkdir(parents=True, exist_ok=False)
    assets = args.output / "assets"
    source = assets / "grove-fhir"
    source.mkdir(parents=True)
    archive = subprocess.run(
        ["git", "-C", str(args.grove_fhir), "archive", manifest["contractRevision"],
         "Scripts", "catalog", "LICENSES", "CONTRIBUTORS.md"],
        check=True, capture_output=True,
    ).stdout
    if hashlib.sha256(archive).hexdigest() != manifest["sourceArchiveSHA256"]:
        raise ValueError("Pinned source archive mismatch")
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        tar.extractall(source, filter="data")
    validator = (args.artifacts / "validator_cli.jar" if args.artifacts
                 else args.grove_fhir / ".build/fhir-tools/validator_cli.jar")
    verified_copy(validator, assets / "validator_cli.jar", manifest["validatorSHA256"])
    for package in manifest["bootstrap"]:
        destination = assets / "packages" / package["file"]
        artifact = (args.artifacts / "packages" if args.artifacts else args.grove_fhir / ".build/fhir-tools") / package["file"]
        verified_copy(artifact, destination, package["sha256"])
        unpack_package(destination, assets / "cache")
    for package in manifest["guides"]:
        destination = assets / "packages" / package["file"]
        artifact = (args.artifacts / "packages" / package["file"] if args.artifacts
                    else args.grove_fhir / package["source"] / "output/package.tgz")
        verified_copy(artifact, destination, package["sha256"])
        with tarfile.open(destination) as tar:
            metadata = json.load(tar.extractfile("package/package.json"))
        if metadata["name"] != package["packageId"] or metadata["version"] != "0.6.0":
            raise ValueError("Unexpected Grove package identity")
        unpack_package(destination, assets / "cache")
    shutil.copyfile(HERE / "manifest.json", assets / "manifest.json")
    verified_copy(HERE / "worker.py", assets / "worker.py", manifest["workerSHA256"])
    shutil.copyfile(HERE / "Dockerfile", args.output / "Dockerfile")
    if args.include_lifecycle_corpus:
        prepare_lifecycle_corpus(args.grove_fhir, args.output / "corpus")
    print("Prepared checksum-verified offline validation context: " + str(args.output))


def prepare_lifecycle_corpus(repository, output):
    # This later corpus tests receiver semantics against the deployed validator.
    # It does not change the validator's independently pinned admission contract.
    lock = json.loads((HERE / "lifecycle-corpus.json").read_bytes())
    archive = subprocess.run(
        ["git", "-C", str(repository), "archive", lock["revision"], lock["path"]],
        check=True, capture_output=True,
    ).stdout
    if hashlib.sha256(archive).hexdigest() != lock["archiveSHA256"]:
        raise ValueError("Pinned lifecycle corpus archive mismatch")
    output.mkdir(parents=True, exist_ok=False)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        tar.extractall(output, filter="data")
    root = output / lock["path"]
    corpus = json.loads((root / "revision-sequences.json").read_bytes())
    if corpus["schemaVersion"] != 0 or len(corpus["sequences"]) != lock["sequences"]:
        raise ValueError("Unexpected lifecycle corpus acceptance matrix")
    shutil.copyfile(HERE / "lifecycle-corpus.json", output / "identity.json")


if __name__ == "__main__":
    main()
