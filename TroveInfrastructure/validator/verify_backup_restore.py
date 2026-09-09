"""Restore the authenticated two-study checkpoint into fresh, disposable stores.

Synthetic, quiescent backup only. This is not a production backup utility or a
stale-backup reconciliation mechanism. Activation requires a separately captured
current-state checkpoint; unknown or stale state leaves runtime access unprovisioned.
"""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import argparse
from contextlib import closing
from dataclasses import dataclass
import hashlib
from importlib.metadata import version
import json
import os
from pathlib import Path
import re
import socket
import time
from typing import Literal, TypedDict
import uuid

from verify_process_restart import Checkpoint, add_stack_arguments, require, run_verification

MAX_OBJECTS = 16
MAX_OBJECT_BYTES = 4 * 1024 * 1024
MAX_DUMP_BYTES = 64 * 1024 * 1024


class RecoveryStateMismatch(RuntimeError):
    """Restored historical bytes do not establish current authority."""


class BackupObject(TypedDict):
    key: str
    file: str
    sha256: str
    bytes: int
    contentType: str
    metadata: dict[str, str]


def require_current_state(restored: dict[str, str], current: dict[str, str] | None) -> None:
    for snapshot in (restored, current):
        if not isinstance(snapshot, dict) or not snapshot:
            raise RuntimeError("Current recovery state is unknown; activation must remain fenced")
        require(all(isinstance(name, str) and re.fullmatch(r"[a-z_][a-z0-9_]*", name)
                    and isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest)
                    for name, digest in snapshot.items()),
                "Recovery state fingerprint is malformed; activation must remain fenced")
    if restored != current:
        raise RecoveryStateMismatch("Backup is not current; activation must remain fenced")


@dataclass(frozen=True)
class InterruptedArtifact:
    identifier: uuid.UUID
    owner: uuid.UUID
    state: Literal["staging", "ready", "discarding"]
    has_object: bool

    @property
    def key(self) -> str:
        # Match ArtifactReference.key's Foundation UUID spelling; S3 keys are case-sensitive.
        return f"artifacts/consents/{str(self.owner).upper()}/{str(self.identifier).upper()}"


INTERRUPTED_CONTENT = b"%PDF-1.4\nSynthetic interrupted upload; never accepted.\n%%EOF\n"


def file_digest(path, maximum):
    require(not path.is_symlink() and path.is_file() and 0 < path.stat().st_size <= maximum,
            "Backup file is missing or outside the bounded fixture")
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_file(path, expected, maximum):
    require(file_digest(path, maximum) == expected, "Backup checksum mismatch; serving must remain stopped")


def object_keys(client, bucket):
    result = client.list_objects_v2(Bucket=bucket, MaxKeys=MAX_OBJECTS + 1)
    keys = [item["Key"] for item in result.get("Contents", [])]
    require(not result.get("IsTruncated") and len(keys) <= MAX_OBJECTS and len(keys) == len(set(keys)),
            "Object inventory exceeds the bounded fixture or is ambiguous")
    return sorted(keys)


def read_object(client, bucket, key):
    result = client.get_object(Bucket=bucket, Key=key)
    try:
        require(0 < result["ContentLength"] <= MAX_OBJECT_BYTES, "Object exceeds the bounded fixture")
        data = result["Body"].read(MAX_OBJECT_BYTES + 1)
        require(len(data) == result["ContentLength"], "Incomplete object backup")
        return data, result.get("ContentType", "application/octet-stream"), result.get("Metadata", {})
    finally:
        result["Body"].close()


class RestoreCheckpoint(Checkpoint):
    def exercise(self):
        try:
            super().exercise()
        except RecoveryStateMismatch:
            require(self.args.post_backup_restrictions and self.summary.get("staleBackupRefused") is True,
                    "Unexpected recovery mismatch, not a verified negative fixture")
            self.assert_stopped()
            self.summary["passed"] = True
        else:
            require(not self.args.post_backup_restrictions, "The stale backup activated instead of being refused")

    def apply_post_backup_restrictions(self) -> None:
        """Advance only the disposable original; never modify the restored history."""
        self.assert_stopped()
        enrollment = uuid.UUID(self.sql("SELECT id FROM enrollments WHERE withdrawn_at IS NULL;"))
        source = uuid.UUID(self.sql("SELECT id FROM source_bindings WHERE revoked_at IS NULL;"))
        original = self.backend(2)
        try:
            participant = self.token("alice@example.com")
            self.api_json(f"/participant/enrollments/{enrollment}/withdraw", participant, "POST")
            self.api_json(f"/participant/sources/{source}/revoke", participant, "POST")
        finally:
            self.stop(original)
        self.assert_stopped()
        require(self.sql(f"SELECT count(*) FROM enrollments WHERE id='{enrollment}' AND withdrawn_at IS NOT NULL;") == "1"
                and self.sql(f"SELECT count(*) FROM source_bindings WHERE id='{source}' AND revoked_at IS NOT NULL;") == "1",
                "Post-backup restrictions did not commit")
        require(self.sql(f"SELECT count(*) FROM audit_events WHERE outcome='succeeded' AND "
                         f"((action='enrollment.withdrawn' AND target_id='{enrollment}') OR "
                         f"(action='source.revoked' AND target_id='{source}'));") == "2",
                "Post-backup restrictions lack their committed audits")

    def capture_current_state(self) -> dict[str, str]:
        self.assert_stopped()
        # This generated role belongs only to the disposable original database.
        # Disable reconnects, but never terminate untracked sessions to force a pass.
        self.sql(f"ALTER ROLE {self.name} NOLOGIN;")
        require(self.sql(f"SELECT count(*) FROM pg_roles WHERE rolname='{self.name}' AND NOT rolcanlogin;") == "1",
                "The original runtime login is not fenced")
        require(self.sql(f"SELECT count(*) FROM pg_stat_activity WHERE usename='{self.name}';") == "0",
                "Original runtime sessions remain; current authority cannot be captured")
        return self.table_digests()

    def authorize_replacement(self, restored: dict[str, str], current: dict[str, str] | None) -> None:
        self.assert_stopped()
        require(self.sql(f"SELECT count(*) FROM pg_roles WHERE rolname='{self.name}';") == "0",
                "Replacement runtime credentials were provisioned before the recovery gate")
        if current is None:
            raise RuntimeError("Current recovery state is unknown; activation must remain fenced")
        try:
            require_current_state(restored, current)
        except RecoveryStateMismatch:
            require(self.args.post_backup_restrictions, "Unexpected state loss during quiescent recovery")
            require(self.sql("SELECT count(*) FROM enrollments WHERE withdrawn_at IS NULL;") == "1"
                    and self.sql("SELECT count(*) FROM source_bindings WHERE revoked_at IS NULL;") == "1",
                    "The restored negative fixture does not contain the superseded authority")
            self.summary.update(staleBackupRefused=True, recoveryAuthority={
                "currentStateCapturedAfterWritersStopped": True,
                "originalRuntimeLoginDisabled": True,
                "postBackupRestrictions": ["enrollment-withdrawal", "source-revocation"],
                "changedTables": sorted(name for name in current if current.get(name) != restored.get(name)),
                "backupRowsVerifiedBeforeGate": True,
                "runtimeRoleAbsent": True, "replacementBackendStarted": False,
                "artifactCleanupStarted": False,
            })
            raise
        self.summary["recoveryAuthority"] = {
            "currentStateCapturedAfterWritersStopped": True,
            "originalRuntimeLoginDisabled": True,
            "verifiedTables": len(current), "runtimeHeldUntilVerified": True,
        }

    def stage_interrupted_artifacts(self) -> tuple[InterruptedArtifact, ...]:
        """Seed precise crash windows only in this stopped, owned synthetic stack."""
        self.assert_stopped()
        owner, study, group = self.sql(
            "SELECT owner_id, study_id, group_id FROM stored_artifacts WHERE purpose='consent' "
            "AND state='retained' ORDER BY id LIMIT 1;"
        ).split("|")
        owner, study = uuid.UUID(owner), uuid.UUID(study)
        group_sql = f"'{uuid.UUID(group)}'" if group else "NULL"
        # No completed PUT; completed PUT before verification; verified but unaccepted;
        # completed DELETE followed by a late PUT from the interrupted writer.
        artifacts = tuple(InterruptedArtifact(uuid.uuid4(), owner, state, has_object)
                          for state, has_object in (("staging", False), ("staging", True),
                                                    ("ready", True), ("discarding", True)))
        digest = hashlib.sha256(INTERRUPTED_CONTENT).hexdigest()
        with closing(self.s3()) as client:
            for artifact in artifacts:
                # Only locally generated UUIDs, fixed states and integers enter this fixture SQL.
                self.sql(f"""INSERT INTO stored_artifacts
                    (id, owner_id, purpose, digest, byte_count, study_id, group_id, state,
                     expires_at, cleanup_after, last_deleted_at)
                    VALUES ('{artifact.identifier}', '{owner}', 'consent', '{digest}',
                            {len(INTERRUPTED_CONTENT)}, '{study}', {group_sql}, '{artifact.state}',
                            now() - interval '1 day', now() - interval '1 hour',
                            {"now() - interval '2 hours'" if artifact.state == 'discarding' else 'NULL'});""")
                if artifact.has_object:
                    client.put_object(Bucket=self.bucket, Key=artifact.key, Body=INTERRUPTED_CONTENT,
                                      ContentType="application/pdf")
        return artifacts

    def check_artifact_cleanup(self, artifacts: tuple[InterruptedArtifact, ...], retained: list[BackupObject]) -> None:
        self.assert_stopped()
        identifiers = ",".join(f"'{artifact.identifier}'" for artifact in artifacts)
        require(len(artifacts) == 4 and len({item.identifier for item in artifacts}) == 4,
                "Incomplete interrupted-artifact fixture")
        require(len(retained) == 4, "Expected both retained publications and both consent PDFs")
        expected_keys = sorted(item["key"] for item in retained)
        for sweep in (1, 2):
            if sweep == 2:
                # Simulate another late PUT after successful deletion. Move only the four
                # fixture deadlines forward; do not sleep for the production retry interval.
                with closing(self.s3()) as client:
                    client.put_object(Bucket=self.bucket, Key=artifacts[-1].key,
                                      Body=INTERRUPTED_CONTENT, ContentType="application/pdf")
                self.sql(f"UPDATE stored_artifacts SET cleanup_after=now() - interval '1 second' "
                         f"WHERE id IN ({identifiers});")
            output = self.run([str(self.evidence / "TroveServer"), "cleanup-artifacts", "--limit", "100"],
                              env=self.env, log=f"artifact-cleanup-{sweep}.log")
            (self.evidence / f"artifact-cleanup-{sweep}.stdout.log").write_bytes(output)
            require(self.sql(f"SELECT count(*) FROM stored_artifacts WHERE id IN ({identifiers}) "
                             "AND state='discarding' AND last_deleted_at IS NOT NULL AND cleanup_after > now();") == "4",
                    "Cleanup lost an artifact recovery locator or did not complete its deletion")
            require(self.sql(f"SELECT count(*) FROM audit_events WHERE action='artifact.discard.scheduled' "
                             f"AND outcome='succeeded' AND target_id IN ({identifiers});") == str(4 * sweep),
                    "Restored cleanup lacks one committed audit per claim")
            with closing(self.s3()) as client:
                require(object_keys(client, self.bucket) == expected_keys,
                        "Cleanup left an abandoned object or deleted a retained artifact")
                for item in retained:
                    data, content_type, metadata = read_object(client, self.bucket, item["key"])
                    require(hashlib.sha256(data).hexdigest() == item["sha256"]
                            and content_type == item["contentType"] and metadata == item["metadata"],
                            "Cleanup changed a retained artifact")
        self.summary["interruptedArtifactRecovery"] = {
            "records": len(artifacts), "initialObjects": sum(item.has_object for item in artifacts),
            "sweeps": 2, "latePutRemoved": True, "recoveryLocatorsRetained": True,
            "cleanupAudits": 8, "retainedObjectsUnchanged": len(retained),
            "restrictedRuntimeCommand": True,
        }

    def s3(self):
        # Optional verification dependency; ordinary worker/tooling tests need no SDK.
        import boto3
        from botocore.config import Config
        return boto3.client("s3", endpoint_url=f"http://127.0.0.1:{self.args.s3_port}",
            aws_access_key_id="trove_test", aws_secret_access_key="trove_test", region_name="us-east-1",
            config=Config(connect_timeout=5, read_timeout=10, retries={"total_max_attempts": 1}, proxies={},
                          s3={"addressing_style": "path"}))

    def assert_stopped(self):
        require(bool(self.backends) and all(process.poll() is not None for process in self.backends),
                "A backend still has write/disclosure authority or no stopped backend was established")
        with socket.socket() as probe:
            probe.settimeout(1)
            require(probe.connect_ex(("127.0.0.1", self.args.server_port)) != 0, "Serving is not fenced")

    def table_digests(self) -> dict[str, str]:
        tables = self.sql("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;").splitlines()
        require(bool(tables), "No application tables to verify")
        result = {}
        for table in tables:
            require(re.fullmatch(r"[a-z_][a-z0-9_]*", table) is not None, "Unexpected fixture table identifier")
            raw = self.sql(f"SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), '[]'::jsonb) FROM public.\"{table}\" t;")
            result[table] = hashlib.sha256(raw.encode()).hexdigest()
        return result

    def restore_objects(self, backup: Path, objects: list[BackupObject]) -> None:
        self.assert_stopped()
        require(self.sql(f"SELECT count(*) FROM pg_roles WHERE rolname='{self.name}';") == "0",
                "Object recovery must finish before provisioning runtime credentials")
        with closing(self.s3()) as client:
            client.create_bucket(Bucket=self.bucket)
            require(object_keys(client, self.bucket) == [], "Replacement object store is not empty")
            for item in objects:
                path = backup / item["file"]
                verify_file(path, item["sha256"], MAX_OBJECT_BYTES)
                client.put_object(Bucket=self.bucket, Key=item["key"], Body=path.read_bytes(),
                                  ContentType=item["contentType"], Metadata=item["metadata"])
            require(object_keys(client, self.bucket) == [item["key"] for item in objects], "Restored object inventory changed")
            for item in objects:
                data, content_type, metadata = read_object(client, self.bucket, item["key"])
                require(hashlib.sha256(data).hexdigest() == item["sha256"] and len(data) == item["bytes"]
                        and content_type == item["contentType"] and metadata == item["metadata"], "Restored object changed")
        self.assert_stopped()

    def replace_backend(self, previous):
        self.stop(previous)
        self.assert_stopped()
        interrupted = self.stage_interrupted_artifacts()
        started = time.monotonic()
        backup = self.evidence / "backup"
        backup.mkdir(mode=0o700)
        tables = self.table_digests()
        versions = self.sql("SELECT current_setting('server_version'), extversion FROM pg_extension WHERE extname='timescaledb';")
        dump = backup / "database.dump"
        self.run(["docker", "exec", "--env", "PGPASSWORD=trove_test", self.pg_container,
                  "pg_dump", "-h", "127.0.0.1", "-U", "trove_test", "-d", self.name,
                  "--format=custom", "--no-owner", "--no-acl", "--file", self.container_scripts + "/database.dump"])
        self.run(["docker", "cp", self.pg_container + ":" + self.container_scripts + "/database.dump", str(dump)])
        digest = file_digest(dump, MAX_DUMP_BYTES)
        objects: list[BackupObject] = []
        with closing(self.s3()) as client:
            keys = object_keys(client, self.bucket)
            require(bool(keys), "Consent object backup is empty")
            for index, key in enumerate(keys):
                data, content_type, metadata = read_object(client, self.bucket, key)
                path = backup / f"object-{index}.bin"  # Never interpret an S3 key as a local path.
                path.write_bytes(data)
                objects.append({"key": key, "file": path.name, "sha256": hashlib.sha256(data).hexdigest(),
                                "bytes": len(data), "contentType": content_type, "metadata": metadata})
        manifest = {"schemaVersion": 1, "mode": "quiescent-synthetic-checkpoint", "databaseSHA256": digest,
                    "databaseBytes": dump.stat().st_size, "versions": versions, "tableDigests": tables, "objects": objects,
                    "binarySHA256": self.summary["binarySHA256"], "validatorIdentity": self.identity}
        (backup / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        verify_file(dump, digest, MAX_DUMP_BYTES)
        for item in objects:
            verify_file(backup / item["file"], item["sha256"], MAX_OBJECT_BYTES)
        self.assert_stopped()
        if self.args.post_backup_restrictions:
            self.apply_post_backup_restrictions()
        # Independent of the backup manifest; all original writers are now stopped.
        current = self.capture_current_state()
        (self.evidence / "current-state.json").write_text(json.dumps(current, indent=2) + "\n")
        originals = [self.pg_container, self.storage_container]
        self.run(["docker", "stop", "--time", "10", *originals])
        self.pg_container += "-restored"
        self.storage_container += "-restored"
        self.prepare_stores()
        self.sql(f"CREATE DATABASE {self.name};", database="postgres")
        self.sql("CREATE EXTENSION IF NOT EXISTS timescaledb; SELECT timescaledb_pre_restore();")
        require(self.sql("SELECT current_setting('server_version'), extversion FROM pg_extension WHERE extname='timescaledb';") == versions,
                "Restore requires the same PostgreSQL and Timescale versions")
        self.run(["docker", "cp", str(dump), self.pg_container + ":/tmp/database.dump"])
        self.run(["docker", "exec", "--env", "PGPASSWORD=trove_test", self.pg_container,
                  "pg_restore", "-h", "127.0.0.1", "-U", "trove_test", "-d", self.name,
                  "--exit-on-error", "--no-owner", "--no-acl", "/tmp/database.dump"])
        self.sql("SELECT timescaledb_post_restore();")
        restored = self.table_digests()
        require(restored == tables, "Restored application rows differ from the backup")
        self.authorize_replacement(restored, current)
        self.restore_objects(backup, objects)
        self.provision_runtime()  # Reapply reviewed permissions; never restore old role grants.
        require(self.sql(f"SELECT has_table_privilege('{self.name}', 'audit_events', 'UPDATE') OR "
                         f"has_table_privilege('{self.name}', 'clinical_events', 'DELETE') OR "
                         f"has_schema_privilege('{self.name}', 'public', 'CREATE');") == "f",
                "Restored runtime permissions are broader than the application contract")
        self.assert_stopped()
        require(all(not item["State"]["Running"] for item in json.loads(self.run(["docker", "inspect", *originals]))),
                "Original stores are still available")
        interrupted_keys = {item.key for item in interrupted}
        self.check_artifact_cleanup(interrupted, [item for item in objects if item["key"] not in interrupted_keys])
        self.assert_stopped()
        self.summary["restore"] = {"databaseSHA256": digest, "databaseBytes": dump.stat().st_size,
            "objects": len(objects), "objectBytes": sum(item["bytes"] for item in objects),
            "verifiedTables": len(tables), "versions": versions, "elapsedSeconds": time.monotonic() - started,
            "originalStoresStopped": True, "servingHeldUntilVerified": True, "canonicalRuntimePermissions": True,
            "exclusions": ["post-backup writes/revocations", "erasure reconciliation", "Keycloak recovery",
                           "external side effects", "live PITR", "large recordings", "production RPO/RTO"]}
        return self.backend(2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    add_stack_arguments(parser)
    parser.add_argument("--post-backup-restrictions", action="store_true",
                        help="Prove that a backup predating later withdrawal and source revocation cannot activate")
    args = parser.parse_args()
    dependencies = {}
    for line in Path(__file__).with_name("recovery-requirements.txt").read_text().splitlines():
        if line and not line.startswith("#"):
            name, expected = line.split("==")
            dependencies[name] = version(name)
            require(dependencies[name] == expected, "Install the reviewed recovery verification requirements")
    os.umask(0o077)
    checkpoint = RestoreCheckpoint(args)
    checkpoint.summary["verificationDependencies"] = dependencies
    checkpoint.summary["verificationMode"] = "stale-backup-refusal" if args.post_backup_restrictions else "current-backup-restore"
    run_verification(checkpoint, checkpoint.exercise)
    print("PASS: stale backup refused before runtime activation." if args.post_backup_restrictions else
          "PASS: current quiescent database/object backup restored; two-study authorization and receipts preserved.", flush=True)


if __name__ == "__main__":
    main()
