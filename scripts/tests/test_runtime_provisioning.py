# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import os
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
