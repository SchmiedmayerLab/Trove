"""Revision-bound authoring setup without network or container dependencies."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import ast
import copy
import json
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import Mock, patch
import uuid

from rekey_fixture import recovered_arguments
from test_rekey_fixture import recovery_fixture
from verify_process_restart import Checkpoint, RELAY, ROOT, record_version_identifier, request, response_uuid
import worker


class ProcessRestartAuthoringTests(unittest.TestCase):
    def test_validation_and_publication_use_the_same_reviewed_revision(self):
        study, revision, candidate_id = [str(uuid.uuid4()) for _ in range(3)]
        checkpoint = object.__new__(Checkpoint)
        checkpoint.api_json = Mock(side_effect=[
            {"status": "valid", "draftRevision": revision, "candidate": {"id": candidate_id, "publicationRevision": 1}},
            {"id": candidate_id, "studyId": study, "revision": 1},
        ])
        checkpoint.publish_draft(study, "synthetic-token", revision)
        validation, publication = checkpoint.api_json.call_args_list
        self.assertEqual(validation.args[0], f"/studies/{study}/draft/validations")
        self.assertEqual(publication.args, (f"/studies/{study}/publish", "synthetic-token", "POST", {"validationId": candidate_id}))
        self.assertEqual(validation.kwargs["headers"], {"If-Match": f'"{revision}"'})
        self.assertEqual(publication.kwargs["headers"], validation.kwargs["headers"])

    def test_malformed_or_mismatched_candidate_never_reaches_publication(self):
        study, revision, candidate_id = [str(uuid.uuid4()) for _ in range(3)]
        for candidate in ({}, {"status": "valid", "draftRevision": revision, "candidate": {"id": "invalid"}},
                          {"status": "invalid", "draftRevision": revision, "candidate": {"id": candidate_id, "publicationRevision": 1}},
                          {"status": "valid", "draftRevision": str(uuid.uuid4()), "candidate": {"id": candidate_id, "publicationRevision": 1}},
                          {"status": "valid", "draftRevision": revision, "candidate": {"id": candidate_id, "publicationRevision": True}}):
            with self.subTest(candidate=candidate):
                checkpoint = object.__new__(Checkpoint)
                checkpoint.api_json = Mock(return_value=candidate)
                with self.assertRaises(RuntimeError):
                    checkpoint.publish_draft(study, "synthetic-token", revision)
                self.assertEqual(checkpoint.api_json.call_count, 1)

    def test_publication_receipt_must_match_the_candidate(self):
        study, revision, candidate_id = [str(uuid.uuid4()) for _ in range(3)]
        for field, value in (("id", str(uuid.uuid4())), ("studyId", str(uuid.uuid4())), ("revision", 2)):
            checkpoint = object.__new__(Checkpoint)
            published = {"id": candidate_id, "studyId": study, "revision": 1, field: value}
            checkpoint.api_json = Mock(side_effect=[
                {"status": "valid", "draftRevision": revision, "candidate": {"id": candidate_id, "publicationRevision": 1}}, published,
            ])
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                checkpoint.publish_draft(study, "synthetic-token", revision)
            self.assertEqual(checkpoint.api_json.call_count, 2)

    def test_api_helper_forwards_precondition_and_rejects_missing_identity(self):
        checkpoint = object.__new__(Checkpoint)
        checkpoint.api = "http://127.0.0.1:8080/api/v0"
        with patch("verify_process_restart.request", return_value=b"{}") as request:
            checkpoint.api_json("/studies/example", "synthetic-token", "PATCH", {}, headers={"If-Match": '"revision"'})
            self.assertEqual(request.call_args.kwargs["headers"], {"If-Match": '"revision"'})
        for response in (None, [], {}, {"id": 1}, {"id": "invalid"}):
            with self.subTest(response=response), self.assertRaises(RuntimeError):
                response_uuid(response, "id")


class ProcessRestartIdentityTests(unittest.TestCase):
    def test_relay_forwards_every_body_the_worker_accepts(self):
        # CI and this verifier reach the isolated worker only through this relay.
        self.assertIn(f"if not 0 <= size <= {worker.MAX_BODY}:", RELAY)

    def test_relay_forwards_every_route_the_worker_serves(self):
        # The questionnaire routes are reached through the same relay as event validation.
        relayed = re.search(r"if self\.path not in (\([^)]*\)):", RELAY)
        self.assertIsNotNone(relayed)
        self.assertEqual(ast.literal_eval(relayed.group(1)), ("/health",) + worker.ROUTES)
        source = (ROOT / "TroveInfrastructure/validator/worker.py").read_text()
        self.assertIn("if self.path not in ROUTES", source)

    def test_relay_returns_every_reply_the_worker_sends(self):
        # A truncated diagnostics reply would no longer parse or match its digest.
        self.assertIn(f"data=response.read({worker.MAX_REPLY + 1})", RELAY)

    def test_reused_validator_requires_exact_image_and_private_network_without_mutations(self):
        original = {"Id": "owned-fixture-id", "Image": "sha256:selected", "State": {"Running": True, "StartedAt": "fixture-start"},
                    "NetworkSettings": {"Networks": {"fixture-network": {}}},
                    "HostConfig": {"ReadonlyRootfs": True, "PortBindings": {}}}
        for failure in (None, "image", "stopped", "writable", "published", "networks", "external-egress"):
            with self.subTest(failure=failure):
                container = copy.deepcopy(original)
                network = {"Internal": failure != "external-egress", "Id": "fixture-network-id"}
                if failure == "image": container["Image"] = "sha256:other"
                if failure == "stopped": container["State"]["Running"] = False
                if failure == "writable": container["HostConfig"]["ReadonlyRootfs"] = False
                if failure == "published": container["HostConfig"]["PortBindings"] = {"8080/tcp": [{}]}
                if failure == "networks": container["NetworkSettings"]["Networks"]["other"] = {}
                checkpoint = object.__new__(Checkpoint)
                checkpoint.validator_container = "fixture-worker"
                checkpoint.validator_image = "sha256:selected"
                checkpoint.summary = {}
                checkpoint.run = Mock(side_effect=[json.dumps([container]).encode(), json.dumps([network]).encode()])
                if failure:
                    with self.assertRaises(RuntimeError):
                        checkpoint.reusable_validator_network()
                    self.assertNotIn("reusedValidator", checkpoint.summary)
                else:
                    self.assertEqual(checkpoint.reusable_validator_network(), "fixture-network")
                    self.assertEqual(checkpoint.summary["reusedValidator"]["containerID"], "owned-fixture-id")
                for call in checkpoint.run.call_args_list:
                    self.assertIn("inspect", call.args[0])

    def test_exited_owned_service_fails_before_polling_http_and_records_oom(self):
        checkpoint = object.__new__(Checkpoint)
        checkpoint.containers = ["owned-worker"]
        checkpoint.summary = {}
        checkpoint.run = Mock(return_value=b'{"Running":false,"ExitCode":137,"OOMKilled":true}')
        with patch("verify_process_restart.urllib.request.urlopen") as urlopen:
            with self.assertRaisesRegex(RuntimeError, "exited before readiness"):
                checkpoint.ready("http://127.0.0.1/health", container="owned-worker")
            urlopen.assert_not_called()
        self.assertEqual(checkpoint.summary["failedService"],
                         {"container": "owned-worker", "exitCode": 137, "outOfMemory": True})

    def test_readiness_does_not_inspect_unowned_services(self):
        checkpoint = object.__new__(Checkpoint)
        checkpoint.containers = []
        checkpoint.run = Mock()
        with self.assertRaisesRegex(RuntimeError, "only an owned container"):
            checkpoint.ready("http://127.0.0.1/health", container="unrelated-worker")
        checkpoint.run.assert_not_called()

    def test_receipt_uses_conversion_entry_identity_and_rejects_multiple_records(self):
        bundle = json.loads((ROOT / "TroveServer/Tests/TroveServerTests/Resources/ImmutablePointEvent.json").read_bytes())
        entry = next(item for item in bundle["entry"] if item["resource"]["resourceType"] == "Provenance")
        expected = entry["extension"][0]["valueIdentifier"]
        bundle["identifier"] = {"system": "https://unrelated.test", "value": "transport-envelope"}
        self.assertEqual(record_version_identifier(json.dumps(bundle)), {key: expected[key] for key in ("system", "value")})
        bundle["entry"].append(entry)
        with self.assertRaises(RuntimeError):
            record_version_identifier(json.dumps(bundle))

    def test_recovery_requires_no_store_and_exact_registration(self):
        checkpoint = object.__new__(Checkpoint)
        checkpoint.api = "http://127.0.0.1:8080/api/v0"
        recovery = recovery_fixture()
        body = {"registrationID": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "credentialBase64": "synthetic-private-credential"}
        with patch("verify_process_restart.request", return_value=json.dumps(recovery).encode()) as call:
            actual = checkpoint.recover_identity("synthetic-token", recovery["registration"], body)
            self.assertEqual(recovered_arguments(actual), recovered_arguments(recovery))
            self.assertEqual(call.call_args.kwargs["response_headers"], {"Cache-Control": "no-store"})
            with self.assertRaises(RuntimeError):
                checkpoint.recover_identity("synthetic-token", {"source": {}}, body)

    def test_request_refuses_cacheable_identity_response(self):
        for cache_control in (None, "public", "no-store"):
            response = Mock(status=200, headers={"Cache-Control": cache_control})
            response.read.return_value = b"{}"
            with self.subTest(cache_control=cache_control), patch("verify_process_restart.urllib.request.urlopen") as urlopen:
                urlopen.return_value.__enter__.return_value = response
                if cache_control == "no-store":
                    self.assertEqual(request("http://127.0.0.1/identity", response_headers={"Cache-Control": "no-store"}), b"{}")
                else:
                    with self.assertRaises(RuntimeError):
                        request("http://127.0.0.1/identity", response_headers={"Cache-Control": "no-store"})

    def test_keyring_is_private_and_initialized_once_outside_retained_evidence(self):
        with tempfile.TemporaryDirectory() as private:
            checkpoint = object.__new__(Checkpoint)
            checkpoint.private_directory = Mock(name=private)
            checkpoint.private_directory.name = private
            checkpoint.env = {}
            def initialize(command, **_):
                self.assertEqual(command[:3], ["/fixture/TroveServer", "create-source-keyring", "--output"])
                with Path(command[3]).open("xb") as stream:
                    stream.write(b"synthetic-keyring")
                Path(command[3]).chmod(0o600)
            checkpoint.run = Mock(side_effect=initialize)
            checkpoint.prepare_identity_keyring(Path("/fixture/TroveServer"))
            self.assertEqual(checkpoint.env["SOURCE_IDENTITY_KEYRING_FILE"], str(Path(private) / "keyring.secret"))
            checkpoint.start = Mock(return_value=Mock())
            checkpoint.ready = Mock()
            checkpoint.backends = []
            checkpoint.evidence = Path("/retained-evidence")
            checkpoint.args = Mock(server_port=8080)
            checkpoint.api = "http://127.0.0.1:8080/api/v0"
            checkpoint.backend(1)
            checkpoint.backend(2)
            checkpoint.run.assert_called_once()
            for call in checkpoint.start.call_args_list:
                self.assertEqual(call.args[1]["SOURCE_IDENTITY_KEYRING_FILE"], str(Path(private) / "keyring.secret"))


if __name__ == "__main__":
    unittest.main()
