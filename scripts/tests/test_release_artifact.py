# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

"""Image handoff boundaries, including incomplete and altered candidates."""

import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

import yaml


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_artifact", ROOT / "scripts/release-artifact.py")
assert SPEC is not None and SPEC.loader is not None
RELEASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASE)
REVISION = "a" * 40
IDENTITY = "sha256:" + "b" * 64


class ReleaseArtifactTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()

    def write(self, path: Path, value: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))

    def archive(self, path: Path, identity: str = IDENTITY, *, duplicate: bool = False) -> None:
        with tarfile.open(path, "w") as archive:
            data = json.dumps({"schemaVersion": 2, "manifests": [{"digest": identity}]}).encode()
            for _ in range(2 if duplicate else 1):
                member = tarfile.TarInfo("index.json")
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))

    def candidate(self, architecture: str = "amd64", component: str = "server") -> Path:
        directory = self.root / architecture / component
        scan = directory / "scan"
        scan.mkdir(parents=True)
        self.write(scan / "vulnerabilities.json", {"Metadata": {"ImageID": IDENTITY}})
        self.write(scan / "sbom.cdx.json", {"bomFormat": "CycloneDX"})
        self.write(scan / "database.json", {"NextUpdate": (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()})
        self.write(scan / "result.json", {
            "result": "passed", "vulnerabilities": 0, "negativeControlPassed": True, "image": IDENTITY,
            "reportSHA256": RELEASE.digest(scan / "vulnerabilities.json"),
            "sbomSHA256": RELEASE.digest(scan / "sbom.cdx.json"),
        })
        self.archive(directory / "image.tar")
        self.write(directory / "artifact.json", {
            "schemaVersion": 1, "component": component, "architecture": architecture,
            "source": {"revision": REVISION, "clean": True, "treeSHA256": "c" * 64},
            "run": "123", "attempt": "1", "image": IDENTITY,
            "archiveSHA256": RELEASE.digest(directory / "image.tar"),
            "evidence": {name: RELEASE.digest(scan / name) for name in RELEASE.EVIDENCE},
        })
        return directory

    def verify(self, directory: Path) -> dict[str, object]:
        return RELEASE.verify(directory, "server", "amd64", REVISION, "123", "1")

    def test_all_components_and_architectures_are_required(self) -> None:
        self.candidate()
        with self.assertRaises(ValueError):
            RELEASE.verify_set(self.root, REVISION, "123", "1")
        for architecture, component in (("amd64", "web"), ("arm64", "server"), ("arm64", "web")):
            self.candidate(architecture, component)
        result = RELEASE.verify_set(self.root, REVISION, "123", "1")
        self.assertEqual(set(result["images"]), {"server", "web"})
        self.assertEqual(result["tag"], "sha-" + REVISION + "-123-1")
        path = self.root / "arm64/web/artifact.json"
        altered = RELEASE.object_file(path)
        altered["source"]["treeSHA256"] = "d" * 64
        self.write(path, altered)
        with self.assertRaises(ValueError):
            RELEASE.verify_set(self.root, REVISION, "123", "1")

    def test_registry_preserves_runtime_and_attestation_descriptors(self) -> None:
        plan = self.root / "plan.json"
        self.write(plan, {"sourceRevision": REVISION, "images": {
            component: {architecture: IDENTITY for architecture in RELEASE.ARCHITECTURES}
            for component in RELEASE.COMPONENTS
        }})
        for component in RELEASE.COMPONENTS:
            combined = []
            for architecture in RELEASE.ARCHITECTURES:
                descriptors = [
                    {"digest": "sha256:" + "c" * 64, "size": 100,
                     "platform": {"os": "linux", "architecture": architecture}},
                    {"digest": "sha256:" + "d" * 64, "size": 100,
                     "platform": {"os": "unknown", "architecture": "unknown"},
                     "annotations": {"vnd.docker.reference.type": "attestation-manifest",
                                     "vnd.docker.reference.digest": "sha256:" + "c" * 64}},
                ]
                self.write(self.root / f"{component}-{architecture}.json",
                           {"digest": IDENTITY, "manifests": descriptors})
                combined.extend(descriptors)
            self.write(self.root / f"{component}.json", {"digest": IDENTITY, "manifests": combined})
        self.assertEqual(RELEASE.registry_result(plan, self.root)["sourceRevision"], REVISION)
        path = self.root / "web.json"
        original = RELEASE.object_file(path)
        for descriptors in ([], original["manifests"][:-1], [*original["manifests"], {}]):
            self.write(path, {**original, "manifests": descriptors})
            with self.subTest(descriptors=descriptors), self.assertRaises(ValueError):
                RELEASE.registry_result(plan, self.root)
        self.write(path, original)
        path = self.root / "web-arm64.json"
        original = RELEASE.object_file(path)
        for change in ({"digest": "sha256:" + "e" * 64}, {"manifests": [None]},
                       {"manifests": original["manifests"][:1]}):
            self.write(path, {**original, **change})
            with self.subTest(change=change), self.assertRaises(ValueError):
                RELEASE.registry_result(plan, self.root)

    def test_altered_source_run_component_architecture_and_status_fail(self) -> None:
        directory = self.candidate()
        original = RELEASE.object_file(directory / "artifact.json")
        changes = {"schemaVersion": [True, 2], "component": ["web"], "architecture": ["arm64"],
                   "run": ["124", 123], "attempt": ["2"], "image": ["invalid"], "evidence": [{}],
                   "source": [{"revision": REVISION, "clean": False, "treeSHA256": "c" * 64},
                              {"revision": "d" * 40, "clean": True, "treeSHA256": "c" * 64}]}
        for key, values in changes.items():
            for value in values:
                self.write(directory / "artifact.json", {**original, key: value})
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    self.verify(directory)
        self.write(directory / "artifact.json", original)
        self.verify(directory)

    def test_changed_archive_and_evidence_bytes_fail(self) -> None:
        directory = self.candidate()
        for path in [directory / "image.tar", *(directory / "scan" / name for name in RELEASE.EVIDENCE)]:
            before = path.read_bytes()
            path.write_bytes(before + b" ")
            with self.subTest(path=path.name), self.assertRaises(ValueError):
                self.verify(directory)
            path.write_bytes(before)

    def test_duplicate_or_wrong_archive_identity_fails(self) -> None:
        archive = self.root / "image.tar"
        self.archive(archive, duplicate=True)
        with self.assertRaises(ValueError):
            RELEASE.archive_identity(archive, IDENTITY)
        self.archive(archive, "sha256:" + "d" * 64)
        with self.assertRaises(ValueError):
            RELEASE.archive_identity(archive, IDENTITY)

    def test_symlinked_evidence_is_not_followed(self) -> None:
        external = self.root / "outside.json"
        self.write(external, {})
        link = self.root / "linked.json"
        link.symlink_to(external)
        for function in (RELEASE.object_file, RELEASE.digest):
            with self.assertRaises(ValueError):
                function(link)

    def test_failed_scan_missing_control_and_expired_database_fail(self) -> None:
        directory = self.candidate() / "scan"
        original = RELEASE.object_file(directory / "result.json")
        for change in ({"result": "failed"}, {"negativeControlPassed": False}, {"vulnerabilities": True},
                       {"vulnerabilities": 1}, {"image": "sha256:" + "d" * 64}):
            self.write(directory / "result.json", {**original, **change})
            with self.subTest(change=change), self.assertRaises(ValueError):
                RELEASE.scan_identity(directory, IDENTITY)
        self.write(directory / "result.json", original)
        self.write(directory / "database.json", {"NextUpdate": "2000-01-01T00:00:00Z"})
        with self.assertRaises(ValueError):
            RELEASE.scan_identity(directory, IDENTITY, fresh=True)

    def test_independent_review_and_protected_branches_are_required(self) -> None:
        path = self.root / "environment.json"
        environment = {"name": "candidate-publication", "deployment_branch_policy": {"protected_branches": True},
                       "protection_rules": [{"type": "required_reviewers", "prevent_self_review": True,
                                             "reviewers": [{"type": "User"}]}]}
        self.write(path, environment)
        RELEASE.approval_environment(path)
        for change in ({"name": "other"}, {"protection_rules": []}, {"deployment_branch_policy": None},
                       {"protection_rules": [{"type": "required_reviewers", "prevent_self_review": False, "reviewers": [{}]}]}):
            self.write(path, {**environment, **change})
            with self.assertRaises(ValueError):
                RELEASE.approval_environment(path)

    def test_publication_consumes_both_tested_architectures_without_build_or_deployment(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/publish-images.yml").read_text())
        job = workflow["jobs"]["publish"]
        self.assertEqual(job["environment"], "candidate-publication")
        commands = "\n".join(step.get("run", "") for step in job["steps"])
        self.assertNotIn("docker build ", commands)
        self.assertNotIn("buildx build", commands)
        self.assertNotIn("kubectl", commands)
        self.assertIn("docker image load", commands)
        self.assertIn("docker image push", commands)
        self.assertLess(commands.index("release-artifact.py verify"), commands.index("docker image push"))
        artifacts = [step["with"]["name"] for step in job["steps"] if step.get("uses", "").startswith("actions/download-artifact@")]
        self.assertEqual(set(artifacts), {"Trove-Candidates-amd64", "Trove-Candidates-arm64"})
        stack = yaml.safe_load((ROOT / ".github/workflows/dev-stack.yml").read_text())["jobs"]["smoke-test"]
        self.assertEqual({entry["architecture"] for entry in stack["strategy"]["matrix"]["include"]}, {"amd64", "arm64"})
        commands = "\n".join(step.get("run", "") for step in stack["steps"])
        self.assertLess(commands.index("npm run test:e2e"), commands.index("release-artifact.py package"))
        self.assertIn("--provenance=mode=max --sbom=true", commands)


if __name__ == "__main__":
    unittest.main()
