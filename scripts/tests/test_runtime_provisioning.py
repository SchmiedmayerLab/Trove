# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "TroveInfrastructure/database-operator/grant-runtime.sh"


class RuntimeProvisioningTests(unittest.TestCase):
    def run_fixture(self, **changes):
        with tempfile.TemporaryDirectory(prefix="trove-runtime-grants-") as directory:
            temporary = Path(directory)
            calls = temporary / "calls"
            psql = temporary / "psql"
            psql.write_text("""#!/bin/bash
printf '%s\\n' "$*" >> "$CALL_LOG"
case "$*" in
  *--file*) exit "${SCHEMA_STATUS:-0}" ;;
  *'\\password'*)
    IFS= read -r first
    IFS= read -r second
    [[ "$first" == "$DATABASE_PASSWORD" && "$second" == "$DATABASE_PASSWORD" ]] || exit 21
    exit "${PASSWORD_STATUS:-0}" ;;
esac
""")
            psql.chmod(0o755)
            environment = {
                **os.environ, "PATH": f"{temporary}:{os.environ['PATH']}",
                "CALL_LOG": str(calls), "PGUSER": "trove_operator", "PGDATABASE": "synthetic",
                "PGPASSWORD": "synthetic-operator-only", "DATABASE_USERNAME": "trove_runtime",
                "DATABASE_PASSWORD": "synthetic-runtime-only", **changes,
            }
            result = subprocess.run(["bash", str(SCRIPT)], env=environment, capture_output=True, text=True)
            return result, calls.read_text() if calls.exists() else ""

    def test_password_is_only_sent_on_stdin_before_login_is_enabled(self):
        result, calls = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("synthetic-runtime-only", calls + result.stdout + result.stderr)
        self.assertNotIn("synthetic-operator-only", calls + result.stdout + result.stderr)
        self.assertLess(calls.index("\\password"), calls.index("LOGIN"))

    def test_invalid_identity_and_line_break_password_stop_before_psql(self):
        for values in (
            {"DATABASE_USERNAME": "trove_operator"}, {"DATABASE_USERNAME": "bad;role"},
            {"DATABASE_USERNAME": "r" * 64}, {"DATABASE_PASSWORD": "synthetic-runtime\nsecret"},
            {"DATABASE_PASSWORD": "synthetic-operator-only"},
        ):
            with self.subTest(values=values):
                result, calls = self.run_fixture(**values)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(calls, "")

    def test_schema_and_password_errors_never_enable_login(self):
        for stage in ("SCHEMA_STATUS", "PASSWORD_STATUS"):
            with self.subTest(stage=stage):
                result, calls = self.run_fixture(**{stage: "19"})
                self.assertEqual(result.returncode, 19)
                self.assertNotIn("LOGIN", calls)

    def test_compose_separates_credentials_and_orders_privilege_setup(self):
        compose = (ROOT / "TroveInfrastructure/docker/docker-compose.yml").read_text()
        server = compose.split("  server:\n", 1)[1].split("  server-migrate:\n", 1)[0]
        migration = compose.split("  server-migrate:\n", 1)[1].split("  server-grants:\n", 1)[0]
        grants = compose.split("  server-grants:\n", 1)[1].split("  web:\n", 1)[0]
        self.assertNotIn("DATABASE_OPERATOR_", server)
        self.assertIn("DATABASE_USERNAME: ${DATABASE_OPERATOR_USERNAME}", migration)
        self.assertIn("server-grants:\n        condition: service_completed_successfully", server)
        self.assertIn("server-migrate:\n        condition: service_completed_successfully", grants)
        self.assertNotIn("profiles:", migration)

    def test_sql_rejections_are_errors_not_successful_psql_quit(self):
        source = (SCRIPT.parent / "grant-runtime.sql").read_text()
        self.assertNotIn("\\quit", source)
        self.assertEqual(source.count("RAISE EXCEPTION"), 2)

    def test_runtime_grants_cover_exactly_the_clinical_custody_tables(self):
        migration = (ROOT / "TroveServer/Sources/TroveServer/Migrations/Postgres/CreateClinicalEvents.swift").read_text()
        inventory = migration.split("private static let tables = [", 1)[1].split("]", 1)[0]
        expected = set(re.findall(r'"([a-z_]+)"', inventory))
        source = (SCRIPT.parent / "grant-runtime.sql").read_text()
        clinical_grants = source.split("GRANT SELECT, INSERT ON public.clinical_events,", 1)[1].split("TO", 1)[0]
        actual = {"clinical_events", *re.findall(r"public\.([a-z_]+)", clinical_grants)}
        self.assertEqual(actual, expected)

    def test_recording_transfer_grants_match_append_only_evidence(self):
        migration = (ROOT / "TroveServer/Sources/TroveServer/Migrations/Postgres/CreateRecordingTransfers.swift").read_text()
        inventory = migration.split("static let tables = [", 1)[1].split("]", 1)[0]
        expected = set(re.findall(r'"([a-z_]+)"', inventory))
        source = (SCRIPT.parent / "grant-runtime.sql").read_text()
        grants = source.split("GRANT SELECT, INSERT ON public.recording_transfers,", 1)[1].split("TO", 1)[0]
        actual = {"recording_transfers", *re.findall(r"public\.([a-z_]+)", grants)}
        self.assertEqual(actual, expected)

    def test_language_approvals_admit_only_insertion_and_revocation(self):
        source = (SCRIPT.parent / "grant-runtime.sql").read_text()
        privileges = set()
        for statement in re.findall(r"^GRANT ([^;]+?)\s+TO\s+:\"runtime_name\";", source, re.MULTILINE | re.DOTALL):
            granted, tables = re.split(r"\s+ON\s+", statement, maxsplit=1)
            if re.search(r"public\.questionnaire_language_approvals\b", tables):
                privileges.add(" ".join(granted.split()))
        self.assertEqual(privileges, {"SELECT, INSERT", "UPDATE (revoked_at, revoked_by_issuer, revoked_by_subject)"})

    def test_provider_grants_cover_every_provider_table_without_deletion(self):
        sources = ROOT / "TroveServer/Sources/TroveServer"
        schemas = [*sources.glob("Migrations/Postgres/*Provider*.swift"), sources / "Modules/Provider/ProviderWorkerSchema.swift"]
        expected = {table for path in schemas for table in re.findall(r'schema\("(provider_[a-z_]+)"\)', path.read_text())}
        append_only = set(re.findall(
            r'protect\(table: "(provider_[a-z_]+)"', "".join(path.read_text() for path in schemas)
        ))
        source = (SCRIPT.parent / "grant-runtime.sql").read_text()
        privileges = {}
        for statement in re.findall(r"^GRANT ([^;]+?) TO :\"runtime_name\";", source, re.MULTILINE | re.DOTALL):
            granted, tables = statement.split(" ON ", 1)
            for table in re.findall(r"public\.(provider_[a-z_]+)", tables):
                privileges.setdefault(table, set()).add(" ".join(granted.split()))
        self.assertEqual(set(privileges), expected)
        self.assertEqual(append_only, {"provider_global_scopes", "provider_query_coverage", "provider_conversion_instants"})
        self.assertEqual(privileges, {
            "provider_registrations": {"SELECT, INSERT, UPDATE"}, "provider_connections": {"SELECT, INSERT, UPDATE"},
            "provider_link_intents": {"SELECT, INSERT, UPDATE"}, "provider_checkpoints": {"SELECT, INSERT, UPDATE"},
            "provider_worker_states": {"SELECT, INSERT, UPDATE"},
            "provider_staged_records": {"SELECT, INSERT", "UPDATE (event_id)"},
            "provider_query_coverage": {"SELECT, INSERT"}, "provider_conversion_instants": {"SELECT, INSERT"},
            "provider_global_scopes": {"SELECT, INSERT"}, "provider_dispatch_budgets": {"SELECT, UPDATE"},
        })
        for table in append_only:
            self.assertEqual(privileges[table], {"SELECT, INSERT"})
        # Startup refuses a runtime login that could rewrite, delete or delegate append-only provider evidence.
        check = (sources / "Core/DatabaseRuntimePrivileges.swift").read_text()
        protected = re.search(r"c\.relname IN \(([^)]*)\)", check).group(1)
        protected_tables = re.findall(r"'([a-z_]+)'", protected)
        self.assertLessEqual(append_only, set(protected_tables))
        self.assertIn(f"(SELECT count(*) FROM protected_relations) = {len(set(protected_tables))}", check)
