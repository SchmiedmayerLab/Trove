#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Exercise the synthetic iOS seed against an exact, revision-bound HTTP contract."""

import http.server
import json
import os
import pathlib
import subprocess
import threading
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
CREATED = "11111111-1111-4111-8111-111111111111"
UPDATED = "22222222-2222-4222-8222-222222222222"
CANDIDATE = "33333333-3333-4333-8333-333333333333"


class IOSSeedTests(unittest.TestCase):
    def run_seed(self, patch_status=200, receipt_revision=UPDATED):
        calls = []
        routes = [
            ("POST", "/realms/trove/protocol/openid-connect/token", 200, {"access_token": "synthetic"}),
            ("POST", "/realms/trove/protocol/openid-connect/token", 200, {"access_token": "synthetic"}),
            ("GET", "/participant/profile", 404, {}),
            ("POST", "/participant/profile", 201, {}),
            ("GET", "/participant/enrollments", 200, []),
            ("GET", "/groups", 200, [{"id": "group"}]),
            ("GET", "/groups/group/studies", 200, [{"id": "old", "title": "Trove UI Test Study"}]),
            ("GET", "/studies/old", 200, {"draftRevision": CREATED}),
            ("DELETE", "/studies/old", 204, None),
            ("POST", "/groups/group/studies", 201, {"id": "new", "draftRevision": CREATED}),
            ("PATCH", "/studies/new", patch_status, {"draftRevision": UPDATED}),
            ("POST", "/studies/new/draft/validations", 201, {
                "id": CANDIDATE, "draftRevision": receipt_revision, "publicationRevision": 1,
            }),
            ("POST", "/studies/new/publish", 201, {}),
            ("GET", "/participant/studies", 200, [{"studyId": "new"}]),
        ]

        class Handler(http.server.BaseHTTPRequestHandler):
            def handle_request(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                calls.append((self.command, self.path, dict(self.headers), body))
                method, path, status, response = routes[len(calls) - 1]
                if (self.command, self.path) != (method, path):
                    self.send_error(500)
                    return
                self.send_response(status)
                self.end_headers()
                if response is not None:
                    self.wfile.write(json.dumps(response).encode())

            do_GET = do_POST = do_PATCH = do_DELETE = handle_request

            def log_message(self, *_args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            endpoint = f"http://127.0.0.1:{server.server_port}"
            result = subprocess.run(
                ["bash", str(ROOT / "TroveiOS/scripts/seed-ui-test.sh")],
                env={**os.environ, "KEYCLOAK_URL": endpoint, "SERVER_URL": endpoint,
                     "KEYCLOAK_DEV_PASSWORD": "synthetic", "GITHUB_OUTPUT": ""},
                capture_output=True, timeout=15, check=False,
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
        return result, calls

    def test_seed_publishes_only_the_captured_validation_candidate(self):
        result, calls = self.run_seed()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 14)
        for index, revision in ((8, CREATED), (10, CREATED), (11, UPDATED), (12, UPDATED)):
            self.assertEqual(calls[index][2]["If-Match"], f'"{revision}"')
        self.assertEqual(json.loads(calls[12][3]), {"validationId": CANDIDATE})
        patch = json.loads(calls[10][3])
        self.assertEqual(set(patch), {"consent", "collectionRequirements"})
        self.assertFalse(any("questionnaire" in call[1] for call in calls))

    def test_stale_patch_stops_without_refresh_or_publication(self):
        result, calls = self.run_seed(patch_status=412)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 11)

    def test_receipt_for_a_different_revision_is_never_published(self):
        result, calls = self.run_seed(receipt_revision=CREATED)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 12)

    def test_native_lane_pins_real_manifest_without_a_validator_bypass(self):
        launcher = (ROOT / "TroveiOS/scripts/start-ui-test-stack.sh").read_text()
        self.assertIn("shasum --algorithm 256 TroveInfrastructure/validator/manifest.json", launcher)
        self.assertIn('FHIR_VALIDATOR_IDENTITY="$validator_identity"', launcher)
        self.assertIn("exec env -u FHIR_VALIDATOR_URL", launcher)
        client = (ROOT / "TroveServer/Sources/TroveServer/Modules/FHIR/FHIRValidationClient.swift").read_text()
        self.assertIn("guard let endpoint else { throw Self.unavailable }", client)


if __name__ == "__main__":
    unittest.main()
