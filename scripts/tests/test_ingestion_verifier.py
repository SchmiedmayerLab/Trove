# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]


class IngestionVerifierTests(unittest.TestCase):
    def test_authority_sql_preserves_database_failures(self):
        script = (ROOT / "TroveInfrastructure/docker/verify-timescale.sh").read_text()
        query = script[script.index("docker compose exec"):script.index('\necho "Verified')]
        for status in (0, 19):
            with self.subTest(database_status=status):
                command = f"""set -eu
DATABASE_OPERATOR_USERNAME=synthetic
DATABASE_NAME=synthetic
docker() {{ cat >/dev/null; return {status}; }}
{query}
"""
                result = subprocess.run(["bash", "-c", command], capture_output=True, text=True)
                self.assertEqual(result.returncode, status, result.stderr)

    def test_retired_route_requires_404_and_preserves_transport_failure(self):
        script = ROOT / "TroveInfrastructure/docker/verify-fhir-ingestion.sh"
        for authenticated, anonymous, transport, expected in (
            (404, 404, 0, 0), (200, 404, 0, 1), (404, 200, 0, 1),
            (401, 404, 0, 1), (404, 404, 7, 7),
        ):
            with self.subTest(authenticated=authenticated, anonymous=anonymous, transport=transport):
                command = f"""
curl() {{
    case "$*" in
        */protocol/openid-connect/token*) printf '{{"access_token":"synthetic"}}'; return 0 ;;
    esac
    case "$*" in
        *Authorization*) printf {authenticated} ;;
        *) printf {anonymous} ;;
    esac
    return {transport}
}}
jq() {{ cat >/dev/null; printf synthetic; }}
export KEYCLOAK_DEV_PASSWORD=synthetic
source "$1"
"""
                result = subprocess.run(["bash", "-c", command, "test", str(script)], capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertNotIn("synthetic", result.stdout + result.stderr)
