"""Verify real simulator HealthKit acquisition into an owned two-study backend.

Uses the existing disposable checkpoint stack. Only the named UI test runs; its
success is followed by operator-side custody assertions and a backend restart.
No existing simulator, database, study or participant is modified.
"""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid

from verify_process_restart import Checkpoint, PROFILE, ROOT, add_stack_arguments, require, run_verification


@dataclass(frozen=True)
class CustodyCounts:
    events: int
    points: int
    grants: int
    sources: int
    event_audits: int
    grant_audits: int

    @classmethod
    def parse(cls, value: str) -> CustodyCounts:
        fields = value.split("|")
        if len(fields) != 6 or any(not field.isascii() or not field.isdecimal() for field in fields):
            raise ValueError("Invalid custody count row")
        return cls(*(int(field) for field in fields))


def simulator_identifier(value: str) -> str:
    """Xcode destination matching requires CoreSimulator's uppercase UUID spelling."""
    return str(uuid.UUID(value.strip())).upper()


def require_ui_success(value: object) -> None:
    if not isinstance(value, dict) or value.get("result") != "Passed":
        raise ValueError("UI test did not pass")
    for field, expected in {
        "totalTestCount": 1, "passedTests": 1, "failedTests": 0,
        "skippedTests": 0, "expectedFailures": 0,
    }.items():
        if type(value.get(field)) is not int or value[field] != expected:
            raise ValueError(f"UI result has unexpected {field}")


def require_heart_rate_sample(payload: bytes) -> None:
    resource = json.loads(payload)
    require(isinstance(resource, dict) and resource.get("resourceType") == "Bundle"
            and isinstance(resource.get("entry"), list), "Retained event is not a Bundle")
    observations = [entry["resource"] for entry in resource["entry"]
                    if isinstance(entry, dict) and isinstance(entry.get("resource"), dict)
                    and entry["resource"].get("resourceType") == "Observation"]
    require(len(observations) == 1, "The simulator event must contain exactly one observation")
    observation = observations[0]
    meta, quantity = observation.get("meta"), observation.get("valueQuantity")
    require(isinstance(meta, dict) and isinstance(meta.get("profile"), list) and PROFILE in meta["profile"],
            "The retained observation is not the heart-rate profile")
    require(isinstance(quantity, dict) and type(quantity.get("value")) in (int, float)
            and quantity["value"] == 73 and quantity.get("code") == "/min"
            and quantity.get("system") == "http://unitsofmeasure.org",
            "The retained point does not match the synthetic Health sample")


class AcquisitionCheckpoint(Checkpoint):
    def __init__(self, args: argparse.Namespace):
        super().__init__(args)
        require(args.server_port == 8080 and args.keycloak_port == 8180,
                "The selected UI fixture requires server port 8080 and Keycloak port 8180")
        self.kc_url = "http://localhost:8180"
        self.simulator: str | None = None

    def exercise(self) -> None:
        first = self.backend(1)
        _, _, studies, enrollments, _ = self.prepare_studies()
        self.simulator = simulator_identifier(self.run([
            "xcrun", "simctl", "create", self.name + "-acquisition", self.args.device_type, self.args.runtime,
        ]).decode())
        self.summary["simulatorID"] = self.simulator
        self.summary["simulatorRuntime"] = self.args.runtime
        self.summary["localWorkspace"] = str(self.args.workspace) if self.args.workspace else None
        self.run(["xcrun", "simctl", "boot", self.simulator])
        self.run(["xcrun", "simctl", "bootstatus", self.simulator, "-b"], timeout=180)
        self.run_ui_test()
        before = self.verify_custody(studies)
        self.replace_backend(first)
        require(self.verify_custody(studies) == before, "Restart changed the retained clinical event")
        participant = self.token("alice@example.com")
        self.api_json(f"/participant/enrollments/{enrollments[0]}/withdraw", participant, "POST")
        require(self.verify_custody(studies, withdrawn=True) == before, "Withdrawal changed source custody")
        self.summary.update(passed=True, payloadSHA256=before, eventCount=1, pointCount=1,
                            grantCount=2, restartPreserved=True, withdrawalIsolated=True)

    def run_ui_test(self) -> None:
        result = self.evidence / "HealthKit-Acquisition.xcresult"
        location = (["-workspace", str(self.args.workspace)] if self.args.workspace
                    else ["-project", str(ROOT / "TroveiOS/Trove.xcodeproj")])
        command = [
            "xcodebuild", "test", *location, "-scheme", "Trove",
            "-destination", f"platform=iOS Simulator,id={self.simulator}",
            "-only-testing:TroveUITests/TroveUITests/testHealthKitSampleIsDeliveredAndNotRepeatedAfterRelaunch",
            "-parallel-testing-enabled", "NO", "-onlyUsePackageVersionsFromResolvedFile",
            "-jobs", "4",
            "-testLanguage", "en", "-testRegion", "US",
            "-derivedDataPath", str(self.args.derived_data or self.evidence / "DerivedData"),
            "-resultBundlePath", str(result), "-enableCodeCoverage", "YES",
            "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=-",
        ]
        env = dict(os.environ, TROVE_UI_RAW_LOG=str(self.evidence / "ui-raw.log"))
        # The tracked process group owns Xcode, tee and xcbeautify, including timeout cleanup.
        process = self.start([
            "bash", "-c", 'set -euo pipefail; "$@" 2>&1 | tee "$TROVE_UI_RAW_LOG" | xcbeautify',
            "acquisition-verification", *command,
        ], env, "ui-pretty.log")
        print("Running the real HealthKit UI flow; raw and formatted logs are retained.", flush=True)
        try:
            require(process.wait(timeout=900) == 0, "UI command failed; inspect ui-raw.log and the result bundle")
        finally:
            self.stop(process)
        summary = json.loads(self.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)]))
        require_ui_success(summary)
        self.summary["uiTestsPassed"] = 1
        self.summary["uiResultBundle"] = str(result)

    def verify_custody(self, studies: list[str], *, withdrawn: bool = False) -> str:
        counts = CustodyCounts.parse(self.sql("""SELECT
            (SELECT count(*) FROM clinical_events),
            (SELECT count(*) FROM clinical_point_facts),
            (SELECT count(*) FROM study_data_grants),
            (SELECT count(*) FROM source_bindings),
            (SELECT count(*) FROM audit_events WHERE action='clinical.event.accepted'),
            (SELECT count(*) FROM audit_events WHERE action='study.data.granted');"""))
        require(counts == CustodyCounts(1, 1, 2, 1, 1, 2), "Sample, source, grant or audit custody was lost or duplicated")
        payload = bytes.fromhex(self.sql("SELECT encode(raw_bytes,'hex') FROM clinical_events;"))
        require_heart_rate_sample(payload)
        for study, expected in zip(studies, (0 if withdrawn else 1, 1), strict=True):
            # Only validated UUIDs from this owned fixture enter the operator assertion.
            study = str(uuid.UUID(study))
            actual = self.sql(f"""SELECT count(DISTINCT g.node_id) FROM study_data_grants g
                JOIN enrollments e ON e.id=g.enrollment_id AND e.study_id=g.study_id
                JOIN enrollment_consents c ON c.id=g.consent_id AND c.enrollment_id=e.id AND c.revision=g.revision
                JOIN published_studies p ON p.id=g.publication_id AND p.study_id=g.study_id AND p.revision=g.revision
                JOIN clinical_event_nodes n ON n.id=g.node_id
                JOIN source_bindings s ON s.id=n.source_id AND s.participant_id=e.participant_id
                WHERE g.study_id='{study}' AND e.withdrawn_at IS NULL;""")
            require(actual == str(expected), "Study withdrawal did not preserve independent authorization")
        return hashlib.sha256(payload).hexdigest()

    def cleanup(self) -> None:
        simulator_error: Exception | None = None
        try:
            if self.simulator:
                # A failed boot may already leave the device shut down. Always attempt deletion;
                # its required success, not the shutdown exit code, establishes cleanup.
                with (self.evidence / "simulator-cleanup.log").open("ab") as log:
                    try:
                        subprocess.run(["xcrun", "simctl", "shutdown", self.simulator],
                                       stdout=log, stderr=log, timeout=60, check=False)
                    except (OSError, subprocess.TimeoutExpired) as error:
                        self.summary["simulatorShutdownError"] = type(error).__name__
                self.run(["xcrun", "simctl", "delete", self.simulator])
                self.summary["simulatorRemoved"] = True
        except Exception as error:
            simulator_error = error
            self.summary["simulatorRemoved"] = False
            self.summary["passed"] = False
        finally:
            super().cleanup()
        if simulator_error:
            self.summary["cleanupComplete"] = False
            (self.evidence / "summary.json").write_text(json.dumps(self.summary, indent=2) + "\n")
            raise RuntimeError("Owned simulator cleanup failed; inspect the evidence") from simulator_error


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    add_stack_arguments(parser)
    parser.set_defaults(server_port=8080, keycloak_port=8180)
    parser.add_argument("--runtime", required=True, help="Installed iOS Simulator runtime identifier")
    parser.add_argument("--device-type", default="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")
    parser.add_argument("--workspace", type=Path, help="Explicit local development workspace, when using unpublished Grove changes")
    parser.add_argument("--derived-data", type=Path)
    args = parser.parse_args()
    if args.workspace:
        args.workspace = args.workspace.resolve(strict=True)
        require(args.workspace.is_dir() and args.workspace.suffix == ".xcworkspace", "Expected an Xcode workspace directory")
    if args.derived_data:
        args.derived_data = args.derived_data.resolve()
    os.umask(0o077)
    checkpoint = AcquisitionCheckpoint(args)
    run_verification(checkpoint, checkpoint.exercise)
    print("PASS: one real HealthKit point, two grants, no relaunch duplicate, retained custody after restart and isolated withdrawal.", flush=True)


if __name__ == "__main__":
    main()
