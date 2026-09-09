"""Bounded backup-integrity and serving-fence tests without SDK or Docker dependencies."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import hashlib
import io
from pathlib import Path
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import uuid

from verify_backup_restore import (
    InterruptedArtifact, MAX_OBJECT_BYTES, RecoveryStateMismatch, RestoreCheckpoint,
    file_digest, object_keys, read_object, require_current_state, verify_file,
)
from verify_process_restart import Checkpoint


class BackupRestoreTests(unittest.TestCase):
    def test_object_recovery_requires_absent_runtime_and_exact_restored_payloads(self):
        content = b"synthetic backup"
        item = {"key": "owned/object", "file": "object-0.bin", "bytes": len(content),
                "sha256": hashlib.sha256(content).hexdigest(),
                "contentType": "application/pdf", "metadata": {"fixture": "yes"}}
        for failure in (None, "runtime-role", "nonempty", "inventory", "content", "content-type", "metadata"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                backup = Path(directory)
                (backup / item["file"]).write_bytes(content)
                checkpoint = object.__new__(RestoreCheckpoint)
                checkpoint.name = "owned_fixture"
                checkpoint.bucket = "owned-bucket"
                checkpoint.assert_stopped = Mock()
                checkpoint.sql = Mock(return_value="1" if failure == "runtime-role" else "0")
                checkpoint.s3 = Mock(return_value=Mock())
                inventories = [["unexpected"] if failure == "nonempty" else [],
                               [] if failure == "inventory" else [item["key"]]]
                result = (b"changed" if failure == "content" else content,
                          "text/plain" if failure == "content-type" else item["contentType"],
                          {} if failure == "metadata" else item["metadata"])
                with patch("verify_backup_restore.object_keys", side_effect=inventories), \
                     patch("verify_backup_restore.read_object", return_value=result):
                    if failure:
                        with self.assertRaises(RuntimeError):
                            checkpoint.restore_objects(backup, [item])
                    else:
                        checkpoint.restore_objects(backup, [item])
                        self.assertEqual(checkpoint.assert_stopped.call_count, 2)
                        checkpoint.s3.return_value.put_object.assert_called_once_with(
                            Bucket=checkpoint.bucket, Key=item["key"], Body=content,
                            ContentType=item["contentType"], Metadata=item["metadata"])
                if failure == "runtime-role":
                    checkpoint.s3.assert_not_called()
                else:
                    checkpoint.s3.return_value.close.assert_called_once()

    def test_current_state_requires_disabled_login_and_no_remaining_runtime_sessions(self):
        for failure in (None, "login", "session"):
            with self.subTest(failure=failure):
                checkpoint = object.__new__(RestoreCheckpoint)
                checkpoint.name = "owned_fixture"
                checkpoint.assert_stopped = Mock()
                checkpoint.sql = Mock(side_effect=["", "0" if failure == "login" else "1",
                                                   "1" if failure == "session" else "0"])
                checkpoint.table_digests = Mock(return_value={"enrollments": "a" * 64})
                if failure:
                    with self.assertRaises(RuntimeError):
                        checkpoint.capture_current_state()
                    checkpoint.table_digests.assert_not_called()
                else:
                    self.assertEqual(checkpoint.capture_current_state(), {"enrollments": "a" * 64})
                    checkpoint.assert_stopped.assert_called_once()
                    self.assertEqual(checkpoint.sql.call_args_list[0].args, ("ALTER ROLE owned_fixture NOLOGIN;",))

    def test_activation_requires_complete_current_state_not_only_backup_integrity(self):
        restored = {"enrollments": "a" * 64, "source_bindings": "b" * 64}
        require_current_state(restored, dict(restored))
        for current in (None, {}, {"enrollments": "a" * 64},
                        {**restored, "enrollments": "c" * 64},
                        {**restored, "new_table": "d" * 64},
                        {"invalid-name": "a" * 64}, {"enrollments": "not-a-digest"}):
            with self.subTest(current=current), self.assertRaises(RuntimeError):
                require_current_state(restored, current)
        with self.assertRaises(RuntimeError):
            require_current_state({}, restored)

    def test_replacement_gate_precedes_runtime_activation_and_checks_superseded_authority(self):
        restored, current = {"enrollments": "a" * 64}, {"enrollments": "b" * 64}
        for failure in (None, "runtime-role", "enrollment", "source", "unknown-current"):
            with self.subTest(failure=failure):
                checkpoint = object.__new__(RestoreCheckpoint)
                checkpoint.args = SimpleNamespace(post_backup_restrictions=True)
                checkpoint.name = "owned_fixture"
                checkpoint.summary = {}
                checkpoint.assert_stopped = Mock()
                checkpoint.sql = Mock(side_effect=["1" if failure == "runtime-role" else "0",
                                                   "0" if failure == "enrollment" else "1",
                                                   "0" if failure == "source" else "1"])
                with self.assertRaises(RuntimeError) as raised:
                    checkpoint.authorize_replacement(restored, None if failure == "unknown-current" else current)
                if failure is None:
                    self.assertIsInstance(raised.exception, RecoveryStateMismatch)
                    self.assertTrue(checkpoint.summary["staleBackupRefused"])
                    result = checkpoint.summary["recoveryAuthority"]
                    self.assertTrue(result["runtimeRoleAbsent"])
                    self.assertFalse(result["replacementBackendStarted"])
                    self.assertFalse(result["artifactCleanupStarted"])
                else:
                    self.assertNotIn("staleBackupRefused", checkpoint.summary)

    def test_negative_mode_cannot_report_success_without_verified_refusal(self):
        for result in ("activated", "unverified-mismatch", "verified-refusal"):
            with self.subTest(result=result):
                checkpoint = object.__new__(RestoreCheckpoint)
                checkpoint.args = SimpleNamespace(post_backup_restrictions=True)
                checkpoint.summary = {"staleBackupRefused": result == "verified-refusal"}
                checkpoint.assert_stopped = Mock()
                error = None if result == "activated" else RecoveryStateMismatch("stale")
                with patch.object(Checkpoint, "exercise", side_effect=error):
                    if result == "verified-refusal":
                        checkpoint.exercise()
                        self.assertTrue(checkpoint.summary["passed"])
                        checkpoint.assert_stopped.assert_called_once()
                    else:
                        with self.assertRaises(RuntimeError):
                            checkpoint.exercise()
                        self.assertNotIn("passed", checkpoint.summary)

    def test_retained_source_checks_cannot_pass_reopened_identity_or_missing_audit(self):
        source = {"id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                  "registrationID": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                  "revokedAt": "2026-09-07T00:00:00Z"}
        for failure in (None, "identity", "lookup", "registration", "revocation", "admission", "audit"):
            with self.subTest(failure=failure):
                checkpoint = object.__new__(Checkpoint)
                replies = [dict(source), dict(source), dict(source), {"detail": "Source binding is not active"}]
                if failure == "identity":
                    replies[0]["id"] = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
                if failure in ("lookup", "registration", "revocation"):
                    replies[("lookup", "registration", "revocation").index(failure)]["revokedAt"] = None
                if failure == "admission":
                    replies[3] = {"detail": "An unrelated conflict"}
                checkpoint.api_json = Mock(side_effect=replies)
                checkpoint.sql = Mock(return_value="2" if failure == "audit" else "1")
                if failure:
                    with self.assertRaises(RuntimeError):
                        checkpoint.check_revoked_source(source, "synthetic-token", {})
                else:
                    checkpoint.check_revoked_source(source, "synthetic-token", {})
                    self.assertEqual(checkpoint.api_json.call_count, 4)
                    self.assertEqual(checkpoint.api_json.call_args.args[-1], 409)

    def test_revocation_fixture_requires_valid_identifiers_and_explicit_time(self):
        source = {"id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                  "registrationID": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                  "revokedAt": "2026-09-07T00:00:00Z"}
        for key, value in (("id", "invalid"), ("registrationID", None), ("revokedAt", None),
                           ("revokedAt", "invalid"), ("revokedAt", "2026-09-07T00:00:00")):
            with self.subTest(key=key, value=value):
                checkpoint = object.__new__(Checkpoint)
                checkpoint.api_json = Mock()
                with self.assertRaises((RuntimeError, ValueError)):
                    checkpoint.check_revoked_source({**source, key: value}, "synthetic-token", {})
                checkpoint.api_json.assert_not_called()

    def test_interrupted_fixture_keys_are_owned_and_stable(self):
        owner = uuid.UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        identifier = uuid.UUID("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        artifact = InterruptedArtifact(identifier, owner, "staging", False)
        self.assertEqual(artifact.key, "artifacts/consents/AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA/BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")

    def test_cleanup_verification_requires_locators_audits_and_unchanged_retained_objects(self):
        artifacts = tuple(InterruptedArtifact(uuid.uuid4(), uuid.uuid4(), "discarding", True) for _ in range(4))
        content = b"retained"
        retained = [{"key": str(index), "sha256": hashlib.sha256(content).hexdigest(),
                     "contentType": "application/pdf", "metadata": {}} for index in range(4)]
        # Each negative result must fail the verifier, even if the command exits successfully.
        for failure in (None, "locator", "audit", "inventory", "content"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                checkpoint = object.__new__(RestoreCheckpoint)
                checkpoint.evidence = Path(directory)
                checkpoint.env = {"DATABASE_USERNAME": "restricted-fixture"}
                checkpoint.bucket = "owned"
                checkpoint.summary = {}
                checkpoint.assert_stopped = Mock()
                checkpoint.run = Mock(return_value=b"completed")
                checkpoint.s3 = Mock(return_value=Mock())
                checkpoint.sql = Mock(side_effect=["3" if failure == "locator" else "4",
                                                   "3" if failure == "audit" else "4", "", "4", "8"])
                keys = [item["key"] for item in retained]
                with patch("verify_backup_restore.object_keys", return_value=keys + (["abandoned"] if failure == "inventory" else [])), \
                     patch("verify_backup_restore.read_object", return_value=(b"changed" if failure == "content" else content,
                                                                              "application/pdf", {})):
                    if failure:
                        with self.assertRaises(RuntimeError):
                            checkpoint.check_artifact_cleanup(artifacts, retained)
                        self.assertNotIn("interruptedArtifactRecovery", checkpoint.summary)
                    else:
                        checkpoint.check_artifact_cleanup(artifacts, retained)
                        self.assertEqual(checkpoint.run.call_count, 2)
                        self.assertEqual(checkpoint.summary["interruptedArtifactRecovery"]["cleanupAudits"], 8)
                        for call in checkpoint.run.call_args_list:
                            self.assertEqual(call.args[0][1:], ["cleanup-artifacts", "--limit", "100"])
                            self.assertEqual(call.kwargs["env"], checkpoint.env)
                        checkpoint.s3.return_value.put_object.assert_called_once()

    def test_missing_empty_oversized_symlink_and_changed_files_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "backup"
            expected = hashlib.sha256(b"data").hexdigest()
            with self.assertRaises(RuntimeError):
                verify_file(path, expected, 4)
            for data in (b"", b"changed", b"oops"):
                path.write_bytes(data)
                with self.assertRaises(RuntimeError):
                    verify_file(path, expected, 4)
            path.write_bytes(b"data")
            self.assertEqual(file_digest(path, 4), expected)
            verify_file(path, expected, 4)
            link = Path(directory) / "link"
            link.symlink_to(path)
            with self.assertRaises(RuntimeError):
                verify_file(link, expected, 4)

    def test_inventory_is_complete_unique_and_bounded(self):
        client = Mock()
        for result in ({"IsTruncated": True}, {"Contents": [{"Key": "a"}] * 2},
                       {"Contents": [{"Key": str(index)} for index in range(17)]}):
            client.list_objects_v2.return_value = result
            with self.assertRaises(RuntimeError):
                object_keys(client, "owned")
        client.list_objects_v2.return_value = {"Contents": [{"Key": "b"}, {"Key": "a"}]}
        self.assertEqual(object_keys(client, "owned"), ["a", "b"])
        client.list_objects_v2.assert_called_with(Bucket="owned", MaxKeys=17)

    def test_objects_are_bounded_complete_and_closed(self):
        client = Mock()
        for size, content in ((0, b""), (MAX_OBJECT_BYTES + 1, b""), (4, b"bad"), (2, b"long")):
            body = io.BytesIO(content)
            client.get_object.return_value = {"Body": body, "ContentLength": size}
            with self.assertRaises(RuntimeError):
                read_object(client, "owned", "key")
            self.assertTrue(body.closed)
        body = io.BytesIO(b"data")
        client.get_object.return_value = {"Body": body, "ContentLength": 4, "ContentType": "application/pdf", "Metadata": {"digest": "value"}}
        self.assertEqual(read_object(client, "owned", "key"), (b"data", "application/pdf", {"digest": "value"}))
        self.assertTrue(body.closed)

    def test_unstopped_or_untracked_backend_cannot_pass_restore_fence(self):
        checkpoint = object.__new__(RestoreCheckpoint)
        process = Mock()
        process.poll.return_value = None
        for processes in ([], [process]):
            checkpoint.backends = processes
            with self.assertRaises(RuntimeError), patch("verify_backup_restore.socket.socket") as socket:
                checkpoint.assert_stopped()
            socket.assert_not_called()

    def test_occupied_serving_port_cannot_pass_restore_fence(self):
        checkpoint = object.__new__(RestoreCheckpoint)
        checkpoint.args = Mock(server_port=8080)
        process = Mock()
        process.poll.return_value = 0
        checkpoint.backends = [process]
        with patch("verify_backup_restore.socket.socket") as socket:
            socket.return_value.__enter__.return_value.connect_ex.return_value = 0
            with self.assertRaises(RuntimeError):
                checkpoint.assert_stopped()
            socket.return_value.__enter__.return_value.connect_ex.return_value = 61
            checkpoint.assert_stopped()

    def test_cleanup_failure_cannot_leave_a_passing_verification_record(self):
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = object.__new__(Checkpoint)
            checkpoint.evidence = Path(directory)
            checkpoint.monitor_stop = Mock()
            checkpoint.monitor = None
            checkpoint.processes = []
            checkpoint.containers = []
            checkpoint.network_created = True
            checkpoint.name = "owned-network"
            checkpoint.run = Mock(side_effect=RuntimeError("cleanup failed"))
            checkpoint.summary = {"passed": True}
            checkpoint.memory = {}
            checkpoint.started = time.monotonic()
            with self.assertRaisesRegex(RuntimeError, "cleanup incomplete"):
                checkpoint.cleanup()
            self.assertFalse(checkpoint.summary["passed"])
            self.assertFalse(checkpoint.summary["cleanupComplete"])


if __name__ == "__main__":
    unittest.main()
