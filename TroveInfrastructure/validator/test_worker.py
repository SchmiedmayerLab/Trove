"""Serialization and fail-closed boundary regressions; real validator smoke is separate."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import hashlib
import json
import io
from email.message import Message
import tempfile
import socketserver
import subprocess
from types import SimpleNamespace
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import worker


class QuestionnaireValidationTests(unittest.TestCase):
    def setUp(self):
        self.validator = object.__new__(worker.Validator)
        self.validator.manifest = {"contractRevision": "pinned"}
        self.validator.identity = "sha256:pinned"
        self.validator.questionnaire_rules = Mock(return_value=[])
        self.validator.engine = Mock()
        self.reject = Mock()
        self.error = type("ProducerValidationError", (Exception,), {})
        self.modules = patch.dict(worker.sys.modules, {
            "Scripts.producer_validation.external_validator": SimpleNamespace(reject_validator_errors=self.reject),
            "Scripts.producer_validation.diagnostics": SimpleNamespace(ProducerValidationError=self.error),
        })
        self.modules.start()
        self.addCleanup(self.modules.stop)
        self.resource = {
            "resourceType": "Questionnaire",
            "meta": {"profile": ["https://grovealliance.org/fhir/questionnaire/StructureDefinition/grove-questionnaire"]},
        }

    def validate(self):
        raw = json.dumps(self.resource).encode()
        status, response = self.validator.validate_questionnaire(raw)
        self.assertEqual(response["purpose"], "questionnaire")
        self.assertEqual(response["sha256"], hashlib.sha256(raw).hexdigest())
        return status, response

    def test_runs_both_validation_layers_and_binds_original_bytes(self):
        status, response = self.validate()
        self.assertEqual(status, 200)
        self.assertTrue(response["valid"])
        self.validator.questionnaire_rules.assert_called_once_with(self.resource)
        self.validator.engine.validate.assert_called_once_with(json.dumps(self.resource).encode())
        self.reject.assert_called_once_with(self.validator.engine.validate.return_value, "questionnaire")

    def test_missing_profile_and_companion_failure_do_not_contact_engine(self):
        for change in ("missing", "wrong", "companion"):
            with self.subTest(change=change):
                if change == "missing":
                    self.resource["meta"]["profile"] = []
                elif change == "wrong":
                    self.resource["meta"]["profile"] = ["https://example.org/StructureDefinition/other"]
                else:
                    self.resource["meta"]["profile"] = ["https://grovealliance.org/fhir/questionnaire/StructureDefinition/grove-questionnaire"]
                    self.validator.questionnaire_rules.return_value = [SimpleNamespace(severity="error")]
                status, response = self.validate()
                self.assertEqual((status, response["code"]), (422, "invalid_fhir"))
                self.validator.engine.validate.assert_not_called()

    def test_official_rejection_is_not_success_or_unavailability(self):
        self.reject.side_effect = self.error("private diagnostic")
        status, response = self.validate()
        self.assertEqual((status, response["code"]), (422, "invalid_fhir"))
        self.assertNotIn("private diagnostic", json.dumps(response))

    def test_engine_failure_is_unavailable(self):
        self.validator.engine.validate.side_effect = TimeoutError("private diagnostic")
        status, response = self.validate()
        self.assertEqual((status, response["code"]), (503, "validator_unavailable"))

    def test_invalid_json_never_reaches_rules_or_engine(self):
        status, response = self.validator.validate_questionnaire(b'{"x":1,"x":2}')
        self.assertEqual((status, response["code"], response["purpose"]), (422, "invalid_json", "questionnaire"))
        self.validator.questionnaire_rules.assert_not_called()
        self.validator.engine.validate.assert_not_called()

    def test_routes_do_not_select_each_others_validation(self):
        for path in ("/validate", "/validate/questionnaire"):
            with self.subTest(path=path):
                handler = object.__new__(worker.Handler)
                handler.path = path
                handler.headers = Message()
                handler.headers["Content-Length"] = "2"
                handler.headers["Content-Type"] = "application/fhir+json"
                handler.rfile = io.BytesIO(b'{}')
                handler.connection = Mock()
                handler.server = Mock()
                handler.server.validator.validate.return_value = (200, {})
                handler.server.validator.validate_questionnaire.return_value = (200, {})
                handler.send_result = Mock()
                with patch.object(worker.signal, "alarm"):
                    handler.do_POST()
                selected = handler.server.validator.validate_questionnaire if path.endswith("questionnaire") else handler.server.validator.validate
                other = handler.server.validator.validate if path.endswith("questionnaire") else handler.server.validator.validate_questionnaire
                selected.assert_called_once_with(b'{}')
                other.assert_not_called()


class StrictJSONTests(unittest.TestCase):
    def test_rejects_ambiguous_or_unbounded_serializations(self):
        cases = [
            b'{"x":1,"x":2}', b'{"x":1,"\\u0078":2}', b'\xef\xbb\xbf{}', b'"\xff"',
            b'{"x":NaN}', b'{"x":Infinity}', b'{"x":-Infinity}', b'{"x":1e999}',
            b'{"x":"\\ud800"}', b"[" * 65 + b"0" + b"]" * 65, b"x" * (worker.MAX_BODY + 1),
        ]
        for raw in cases:
            with self.subTest(raw_prefix=raw[:20]), self.assertRaises((ValueError, UnicodeError)):
                worker.strict_json(raw)

    def test_accepts_valid_escaping_and_finite_numbers(self):
        value = worker.strict_json(b'{"x":"[\\\"{", "y":1.234, "z":"\\ud83d\\ude00"}')
        self.assertEqual(str(value["y"]), "1.234")
        self.assertEqual(value["z"], "😀")

    def test_response_is_digest_bound_and_has_no_input(self):
        validator = object.__new__(worker.Validator)
        validator.manifest = {"contractRevision": "pinned"}
        validator.identity = "sha256:pinned"
        raw = b'{"private":"do not echo"}'
        response = validator.response(raw, code="invalid_fhir")
        self.assertEqual(response["sha256"], hashlib.sha256(raw).hexdigest())
        self.assertFalse(response["valid"])
        self.assertNotIn("do not echo", json.dumps(response))
        self.assertLess(len(json.dumps(response)), 2048)

    def test_no_shell_or_network_fallback_in_process_boundary(self):
        source = Path(worker.__file__).read_text()
        self.assertNotIn("shell=True", source)
        self.assertIn('"-no-http-access"', source)
        self.assertIn("stdout=subprocess.DEVNULL", source)
        self.assertIn("stderr=subprocess.DEVNULL", source)
        self.assertIn("timeout=TIMEOUT", source)

    def test_checked_in_manifest_matches_worker_bytes(self):
        path = Path(worker.__file__)
        manifest = json.loads(path.with_name("manifest.json").read_bytes())
        self.assertEqual(manifest["workerSHA256"], hashlib.sha256(path.read_bytes()).hexdigest())

    def test_changed_worker_identity_prevents_startup(self):
        with tempfile.TemporaryDirectory() as directory:
            assets = Path(directory)
            (assets / "manifest.json").write_text(json.dumps({"workerSHA256": "0" * 64}))
            with self.assertRaisesRegex(ValueError, "Worker checksum mismatch"):
                worker.Validator(assets)

    def test_handler_initializes_and_clears_total_read_deadline(self):
        handler = object.__new__(worker.Handler)
        handler.connection = Mock()
        with patch.object(socketserver.StreamRequestHandler, "setup"), patch.object(worker.signal, "signal") as install, \
                patch.object(worker.signal, "alarm") as alarm:
            handler.setup()
            install.assert_called_once()
            alarm.assert_called_once_with(10)
        with patch.object(socketserver.StreamRequestHandler, "finish"), patch.object(worker.signal, "alarm") as alarm:
            handler.finish()
            alarm.assert_called_once_with(0)

    def test_malformed_official_outcome_is_unavailable_not_input_rejection(self):
        for value in ({}, {"issue": []}, {"issue": None}, {"issue": [None]}, {"issue": [{"severity": "unknown"}]}):
            self.assertFalse(worker.outcome_has_valid_issues(value))
        self.assertTrue(worker.outcome_has_valid_issues({"issue": [{"severity": "error"}]}))

    def test_framing_rejections_never_invoke_validator(self):
        cases = [
            ([('Content-Length', '2'), ('Transfer-Encoding', 'chunked')], 400),
            ([('Content-Length', '2'), ('Content-Length', '2')], 400),
            ([('Content-Length', '9' * 100)], 413),
            ([('Content-Length', str(worker.MAX_BODY + 1))], 413),
            ([('Content-Length', '2'), ('Content-Type', 'application/json')], 415),
        ]
        for headers, status in cases:
            with self.subTest(headers=headers):
                handler = object.__new__(worker.Handler)
                handler.path = '/validate'
                handler.headers = Message()
                for name, value in headers:
                    handler.headers[name] = value
                handler.rfile = io.BytesIO(b'{}')
                handler.server = Mock()
                handler.send_result = Mock()
                handler.do_POST()
                self.assertEqual(handler.send_result.call_args.args[0], status)
                handler.server.validator.validate.assert_not_called()

    def test_health_requires_a_live_engine_and_does_not_expose_other_routes(self):
        handler = object.__new__(worker.Handler)
        handler.server = Mock()
        handler.send_result = Mock()
        for path, ready, status in (("/health", True, 200), ("/health", False, 503), ("/stop", True, 404)):
            handler.path = path
            handler.server.validator.engine.ready = ready
            handler.do_GET()
            handler.send_result.assert_called_with(status, {"ready": status == 200})
        handler.server.validator.validate.assert_not_called()


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.engine = worker.Engine(Path("/synthetic/assets"), {"guides": []}, Path("/synthetic/home"))
        self.process = Mock()
        self.process.poll.return_value = None
        self.engine.process = self.process
        self.engine.port = 8081
        self.outcome = {"resourceType": "OperationOutcome", "issue": [{"severity": "information", "code": "informational"}]}
        self.connection = Mock()
        self.response = self.connection.getresponse.return_value
        self.response.status = 200
        self.response.read.return_value = json.dumps(self.outcome).encode()
        client = patch.object(worker.http.client, "HTTPConnection", return_value=self.connection)
        self.client = client.start()
        alarm = patch.object(worker.signal, "alarm")
        self.alarm = alarm.start()
        self.addCleanup(client.stop)
        self.addCleanup(alarm.stop)

    def test_reuses_one_engine_and_only_forwards_fixed_validation_parameters(self):
        with patch.object(self.engine, "start") as start:
            for raw in (b'{"first":1}', b'{"second":2}'):
                self.assertEqual(self.engine.validate(raw), self.outcome)
                self.connection.request.assert_called_with("POST", "/validateResource", body=raw,
                    headers={"Content-Type": "application/fhir+json", "Accept": "application/fhir+json"})
            start.assert_not_called()
        self.assertIs(self.engine.process, self.process)
        self.process.terminate.assert_not_called()
        self.client.assert_called_with("127.0.0.1", 8081, timeout=worker.TIMEOUT)
        self.response.read.assert_called_with(worker.MAX_OUTCOME + 1)
        self.assertEqual([call.args[0] for call in self.alarm.call_args_list], [worker.TIMEOUT, 0, worker.TIMEOUT, 0])

    def test_timeout_discards_engine_and_clears_deadline(self):
        self.connection.getresponse.side_effect = TimeoutError()
        with self.assertRaises(TimeoutError):
            self.engine.validate(b'{}')
        self.process.terminate.assert_called_once()
        self.process.wait.assert_called_once_with(timeout=5)
        self.assertIsNone(self.engine.process)
        self.assertFalse(self.engine.ready)
        self.connection.close.assert_called_once()
        self.alarm.assert_called_with(0)

    def test_malformed_or_oversized_outcome_discards_engine(self):
        for body in (b'{}', b'[]', b'{"resourceType":"OperationOutcome","issue":[]}',
                     b'{"resourceType":"OperationOutcome","issue":[{"severity":"unknown"}]}',
                     b'{"x":1,"x":2}', b'x' * (worker.MAX_OUTCOME + 1)):
            with self.subTest(prefix=body[:40]):
                self.engine.process = self.process
                self.engine.port = 8081
                self.response.read.return_value = body
                with self.assertRaises(ValueError):
                    self.engine.validate(b'{}')
                self.assertFalse(self.engine.ready)

    def test_non_success_or_redirect_is_not_a_validation_result(self):
        for status in (301, 400, 422, 500):
            with self.subTest(status=status):
                self.engine.process = self.process
                self.engine.port = 8081
                self.response.status = status
                with self.assertRaises(ValueError):
                    self.engine.validate(b'{}')
                self.assertFalse(self.engine.ready)

    def test_error_outcome_keeps_engine_usable(self):
        self.outcome["issue"][0]["severity"] = "error"
        self.response.read.return_value = json.dumps(self.outcome).encode()
        self.assertEqual(self.engine.validate(b'{}'), self.outcome)
        self.process.terminate.assert_not_called()

    def test_termination_escalates_but_never_forgets_a_live_process(self):
        self.process.wait.side_effect = subprocess.TimeoutExpired("java", 5)
        with self.assertRaises(subprocess.TimeoutExpired):
            self.engine.close()
        self.process.kill.assert_called_once()
        self.assertIs(self.engine.process, self.process)
        self.assertFalse(self.engine.ready)

    def test_a_later_request_restarts_a_discarded_engine(self):
        self.engine.process = None
        self.engine.port = None
        def started():
            self.engine.process = self.process
            self.engine.port = 8081
        with patch.object(self.engine, "start", side_effect=started) as start:
            self.engine.validate(b'{}')
            start.assert_called_once()

    def test_start_uses_only_pinned_packages_and_loopback_readiness(self):
        self.engine.manifest = {"guides": [{"file": "reviewed.tgz"}]}
        reservation = Mock()
        reservation.getsockname.return_value = ("127.0.0.1", 8123)
        self.response.status = 405
        self.response.read.return_value = b"Method not allowed"
        with patch.object(worker.socket, "socket") as socket, \
                patch.object(worker.subprocess, "Popen", return_value=self.process) as popen:
            socket.return_value.__enter__.return_value = reservation
            self.engine.start()
        reservation.bind.assert_called_once_with(("127.0.0.1", 0))
        self.assertEqual(popen.call_args.args[0], [
            "java", "-Xmx1400m", "-Djava.net.preferIPv4Stack=true", "-Duser.home=/synthetic/home",
            "-jar", "/synthetic/assets/validator_cli.jar", "server", "8123",
            "-version", "4.0.1", "-tx", "n/a", "-no-http-access", "-ig", "/synthetic/assets/packages/reviewed.tgz"
        ])
        self.connection.request.assert_called_once_with("GET", "/validateResource")
        self.assertTrue(self.engine.ready)

    def test_start_reaps_an_engine_that_exits_before_readiness(self):
        self.engine.process = None
        self.process.poll.return_value = 1
        with patch.object(worker.socket, "socket"), \
                patch.object(worker.subprocess, "Popen", return_value=self.process):
            with self.assertRaisesRegex(ValueError, "initialization failed"):
                self.engine.start()
        self.process.wait.assert_called_once_with(timeout=5)
        self.assertFalse(self.engine.ready)
        self.assertIsNone(self.engine.process)


if __name__ == "__main__":
    unittest.main()
