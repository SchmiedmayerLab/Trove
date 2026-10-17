"""Explicit tool artifacts retain the same checksum checks as the checkout cache."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import prepare


class PrepareTests(unittest.TestCase):
    def test_lifecycle_corpus_requires_the_locked_archive_and_acceptance_matrix(self):
        for changed, count in ((False, 35), (True, 35), (False, 34)):
            with self.subTest(changed=changed, count=count), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                archive = io.BytesIO()
                content = json.dumps({"schemaVersion": 0, "sequences": list(range(count))}).encode()
                with tarfile.open(fileobj=archive, mode="w") as tar:
                    header = tarfile.TarInfo("corpus/revision-sequences.json")
                    header.size = len(content)
                    tar.addfile(header, io.BytesIO(content))
                raw = archive.getvalue()
                lock = {"revision": "reviewed-corpus", "path": "corpus", "sequences": 35,
                        "archiveSHA256": hashlib.sha256(b"different" if changed else raw).hexdigest()}
                (root / "lifecycle-corpus.json").write_text(json.dumps(lock))
                with patch.object(prepare, "HERE", root), \
                     patch.object(prepare.subprocess, "run", return_value=SimpleNamespace(stdout=raw)) as run:
                    if changed or count != 35:
                        with self.assertRaises(ValueError):
                            prepare.prepare_lifecycle_corpus(root / "source", root / "output")
                    else:
                        prepare.prepare_lifecycle_corpus(root / "source", root / "output")
                        self.assertEqual(json.loads((root / "output/identity.json").read_text()), lock)
                    self.assertEqual(run.call_args.args[0][-2:], ["reviewed-corpus", "corpus"])

    def test_default_and_explicit_jars_are_verified_without_changing_the_cache(self):
        for explicit, changed in ((False, False), (True, False), (True, True)):
            with self.subTest(explicit=explicit, changed=changed), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                archive = io.BytesIO()
                with tarfile.open(fileobj=archive, mode="w"):
                    pass
                source = root / "checkout"
                cached = source / ".build/fhir-tools/validator_cli.jar"
                cached.parent.mkdir(parents=True)
                cached.write_bytes(b"cached")
                artifacts = root / "artifacts"
                artifacts.mkdir()
                alternate = artifacts / "validator_cli.jar"
                alternate.write_bytes(b"changed" if changed else b"reviewed")
                worker = b"synthetic worker, never executed"
                (root / "worker.py").write_bytes(worker)
                (root / "Dockerfile").write_text("FROM scratch\n")
                manifest = {
                    "contractRevision": "reviewed-contract",
                    "sourceArchiveSHA256": hashlib.sha256(archive.getvalue()).hexdigest(),
                    "validatorSHA256": hashlib.sha256(b"reviewed" if explicit else b"cached").hexdigest(),
                    "bootstrap": [], "guides": [],
                    "workerSHA256": hashlib.sha256(worker).hexdigest(),
                }
                (root / "manifest.json").write_text(json.dumps(manifest))
                output = root / "output"
                args = ["prepare.py", "--grove-fhir", str(source), "--output", str(output)]
                if explicit:
                    args += ["--artifacts", str(artifacts)]
                with patch.object(prepare, "HERE", root), patch("sys.argv", args), \
                     patch.object(prepare.subprocess, "run", return_value=SimpleNamespace(stdout=archive.getvalue())):
                    if changed:
                        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                            prepare.main()
                    else:
                        prepare.main()
                        self.assertEqual((output / "assets/validator_cli.jar").read_bytes(),
                                         b"reviewed" if explicit else b"cached")
                self.assertEqual(cached.read_bytes(), b"cached")

    def test_explicit_packages_use_repository_checksums_not_input_metadata(self):
        for changed in (None, "bootstrap.tgz", "guide.tgz"):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                artifacts = root / "artifacts"
                packages = artifacts / "packages"
                packages.mkdir(parents=True)
                archive = io.BytesIO()
                with tarfile.open(fileobj=archive, mode="w"):
                    pass
                worker = b"synthetic worker, never executed"
                (root / "worker.py").write_bytes(worker)
                (root / "Dockerfile").write_text("FROM scratch\n")
                (artifacts / "validator_cli.jar").write_bytes(b"reviewed")
                # Untrusted input metadata is never a replacement for repository pins.
                (artifacts / "manifest.json").write_text("not a manifest")
                digests = {}
                for name in ("bootstrap", "guide"):
                    metadata = json.dumps({"name": name, "version": "0.6.0"}).encode()
                    header = tarfile.TarInfo("package/package.json")
                    header.size = len(metadata)
                    package = packages / f"{name}.tgz"
                    with tarfile.open(package, "w:gz") as tar:
                        tar.addfile(header, io.BytesIO(metadata))
                    digests[name] = hashlib.sha256(package.read_bytes()).hexdigest()
                manifest = {
                    "contractRevision": "reviewed-contract",
                    "sourceArchiveSHA256": hashlib.sha256(archive.getvalue()).hexdigest(),
                    "validatorSHA256": hashlib.sha256(b"reviewed").hexdigest(),
                    "workerSHA256": hashlib.sha256(worker).hexdigest(),
                    "bootstrap": [{"file": "bootstrap.tgz", "sha256": digests["bootstrap"]}],
                    "guides": [{"file": "guide.tgz", "sha256": digests["guide"],
                                "packageId": "guide", "source": "guide-source"}],
                }
                (root / "manifest.json").write_text(json.dumps(manifest))
                if changed:
                    (packages / changed).write_bytes(b"changed")
                output = root / "output"
                args = ["prepare.py", "--grove-fhir", str(root / "checkout"),
                        "--artifacts", str(artifacts), "--output", str(output)]
                with patch.object(prepare, "HERE", root), patch("sys.argv", args), \
                     patch.object(prepare.subprocess, "run", return_value=SimpleNamespace(stdout=archive.getvalue())):
                    if changed:
                        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                            prepare.main()
                    else:
                        prepare.main()
                        self.assertEqual(json.loads((output / "assets/manifest.json").read_bytes()), manifest)
                        for name in ("bootstrap", "guide"):
                            self.assertTrue((output / f"assets/cache/{name}#0.6.0/package/package.json").is_file())


if __name__ == "__main__":
    unittest.main()
