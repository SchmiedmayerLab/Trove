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


MESSAGE_ID = "http://hl7.org/fhir/StructureDefinition/operationoutcome-message-id"


def official_issue(severity, message_id, expression, text="synthetic finding"):
    return {"severity": severity, "code": "processing", "details": {"text": text}, "expression": [expression],
            "extension": [{"url": MESSAGE_ID, "valueString": message_id}]}


def outcome(*issues):
    return {"resourceType": "OperationOutcome", "issue": list(issues) or [official_issue("information", "All_OK", "Questionnaire")]}


class QuestionnaireValidationTests(unittest.TestCase):
    def setUp(self):
        self.validator = object.__new__(worker.Validator)
        self.validator.manifest = {"contractRevision": "pinned"}
        self.validator.identity = "sha256:pinned"
        self.validator.questionnaire_rules = Mock(return_value=[])
        self.validator.engine = Mock()
        self.validator.engine.validate.return_value = outcome()
        self.resource = {
            "resourceType": "Questionnaire",
            "meta": {"profile": [worker.QUESTIONNAIRE_PROFILE]},
            "language": "en-US",
            "item": [{"linkId": "a", "text": "Question", "_text": {"extension": [
                {"url": worker.TRANSLATION, "extension": [{"url": "lang", "valueCode": "de"}, {"url": "content", "valueString": "Frage"}]}
            ]}}],
        }

    def validate(self):
        raw = json.dumps(self.resource).encode()
        status, response = self.validator.validate_questionnaire(raw)
        self.assertEqual(response["purpose"], "questionnaire")
        self.assertEqual(response["sha256"], hashlib.sha256(raw).hexdigest())
        self.assertEqual((response["contractRevision"], response["validatorIdentity"]), ("pinned", "sha256:pinned"))
        return status, response

    def test_runs_both_validation_layers_and_binds_original_bytes(self):
        status, response = self.validate()
        self.assertEqual((status, response["status"]), (200, "valid"))
        self.validator.questionnaire_rules.assert_called_once_with(self.resource)
        self.validator.engine.validate.assert_called_once_with(json.dumps(self.resource).encode())
        self.assertEqual(response["diagnostics"][0]["rule"], "All_OK")

    def test_missing_profile_does_not_contact_engine(self):
        for profiles in ([], ["https://example.org/StructureDefinition/other"]):
            with self.subTest(profiles=profiles):
                self.resource["meta"]["profile"] = profiles
                status, response = self.validate()
                self.assertEqual((status, response["status"]), (422, "invalid"))
                self.assertEqual(response["diagnostics"][0]["rule"], "profile-required")
                self.validator.engine.validate.assert_not_called()

    def test_reports_companion_and_official_findings_with_rule_path_and_language(self):
        self.validator.questionnaire_rules.return_value = [
            SimpleNamespace(rule="qg-version-1", path="Questionnaire.version", message="Version is not valid", severity="error")]
        self.validator.engine.validate.return_value = outcome(
            official_issue("warning", "Synthetic_Warning", "Questionnaire.item[0]"),
            official_issue("error", "Inv_Failed", "Questionnaire.item[0].text.extension[0]", "Constraint failed: qg-translation-1"))
        status, response = self.validate()
        self.assertEqual((status, response["status"]), (422, "invalid"))
        self.assertEqual([(item["severity"], item["source"], item["rule"], item["path"], item.get("language")) for item in response["diagnostics"]], [
            ("error", "grove", "qg-version-1", "Questionnaire.version", None),
            ("error", "fhir", "Inv_Failed", "Questionnaire.item[0].text.extension[0]", "de"),
            ("warning", "fhir", "Synthetic_Warning", "Questionnaire.item[0]", None),
        ])

    def test_skipped_official_check_is_incomplete_not_valid(self):
        for message_id in worker.NOT_EVALUATED:
            with self.subTest(message_id=message_id):
                self.validator.engine.validate.return_value = outcome(official_issue("warning", message_id, "Questionnaire"))
                status, response = self.validate()
                self.assertEqual((status, response["status"]), (422, "incomplete"))

    def test_engine_failure_is_unavailable_unless_rules_already_failed(self):
        self.validator.engine.validate.side_effect = TimeoutError("private diagnostic")
        status, response = self.validate()
        self.assertEqual((status, response["status"], response["diagnostics"]), (503, "unavailable", []))
        self.assertNotIn("private diagnostic", json.dumps(response))
        self.validator.questionnaire_rules.return_value = [
            SimpleNamespace(rule="qg-version-1", path="Questionnaire.version", message="Version is not valid", severity="error")]
        status, response = self.validate()
        self.assertEqual((status, response["status"]), (422, "invalid"))

    def test_unknown_companion_severity_counts_as_an_error(self):
        self.validator.questionnaire_rules.return_value = [
            SimpleNamespace(rule="qg-synthetic", path="Questionnaire", message="Synthetic", severity="fatal")]
        status, response = self.validate()
        self.assertEqual((status, response["status"], response["diagnostics"][0]["severity"]), (422, "invalid", "error"))

    def test_every_route_runs_exclusively(self):
        validator = object.__new__(worker.Validator)
        held = []
        for method in ("validate", "validate_questionnaire", "validate_questionnaire_response"):
            setattr(validator, method, Mock(side_effect=lambda raw: held.append(worker.VALIDATION_LOCK.locked()) or (200, {})))
        for path in worker.ROUTES:
            validator.route(path)(b"{}")
        self.assertEqual(held, [True, True, True])
        self.assertFalse(worker.VALIDATION_LOCK.locked())

    def test_companion_failure_to_read_is_invalid(self):
        self.validator.questionnaire_rules.side_effect = TypeError("private")
        status, response = self.validate()
        self.assertEqual((status, response["status"], response["diagnostics"][0]["rule"]), (422, "invalid", "questionnaire-rules"))

    def test_invalid_json_never_reaches_rules_or_engine(self):
        status, response = self.validator.validate_questionnaire(b'{"x":1,"x":2}')
        self.assertEqual((status, response["status"], response["purpose"]), (422, "invalid", "questionnaire"))
        self.assertEqual(response["diagnostics"][0]["rule"], "invalid-json")
        self.validator.questionnaire_rules.assert_not_called()
        self.validator.engine.validate.assert_not_called()

    def test_diagnostics_are_bounded_in_count_and_size(self):
        self.validator.engine.validate.return_value = outcome(*[
            official_issue("error", "Synthetic", f"Questionnaire.item[{index}]", "é" * 5000) for index in range(500)])
        status, response = self.validate()
        self.assertEqual(response["status"], "invalid")
        self.assertLessEqual(len(response["diagnostics"]), worker.MAX_DIAGNOSTICS)
        self.assertEqual(response["omittedDiagnostics"], 500 - len(response["diagnostics"]))
        self.assertLessEqual(len(json.dumps(response, ensure_ascii=False).encode()), worker.MAX_REPLY)
        self.assertTrue(all(len(item["message"]) <= 1000 for item in response["diagnostics"]))

    def test_routes_do_not_select_each_others_validation(self):
        methods = ("validate", "validate_questionnaire", "validate_questionnaire_response")
        for path, selected in zip(worker.ROUTES, methods):
            with self.subTest(path=path):
                handler = object.__new__(worker.Handler)
                handler.path = path
                handler.headers = Message()
                handler.headers["Content-Length"] = "2"
                handler.headers["Content-Type"] = "application/fhir+json"
                handler.rfile = io.BytesIO(b'{}')
                handler.connection = Mock()
                handler.server = Mock()
                validator = object.__new__(worker.Validator)
                for method in methods:
                    setattr(validator, method, Mock(return_value=(200, {})))
                handler.server.validator = validator
                handler.send_result = Mock()
                with patch.object(worker.signal, "alarm"):
                    handler.do_POST()
                getattr(validator, selected).assert_called_once_with(b'{}')
                for other in set(methods) - {selected}:
                    getattr(validator, other).assert_not_called()


def file_outcome(path, *issues):
    return {"resourceType": "OperationOutcome", "extension": [{"url": worker.FILE_EXTENSION, "valueString": str(path)}],
            "issue": list(issues) or [official_issue("information", "All_OK", "QuestionnaireResponse")]}


class QuestionnaireResponseValidationTests(unittest.TestCase):
    def setUp(self):
        self.validator = object.__new__(worker.Validator)
        self.validator.manifest = {"contractRevision": "pinned", "guides": [{"file": "reviewed.tgz"}]}
        self.validator.identity = "sha256:pinned"
        self.validator.assets = Path("/synthetic/assets")
        self.validator.home = Path("/synthetic/home")
        self.validator.engine = Mock()
        self.questionnaire = b'{"resourceType" : "Questionnaire", "meta":{"profile":["' + worker.QUESTIONNAIRE_PROFILE.encode() + b'"]}, "x": 1.50}'
        self.response = b'{"resourceType":"QuestionnaireResponse","meta":{"profile":["' + worker.RESPONSE_PROFILE.encode() + b'"]}}'

    def raw(self, questionnaire=None, response=None):
        return (worker.PAIR_PREFIX.encode() + (questionnaire or self.questionnaire) + worker.PAIR_INFIX.encode()
                + (response or self.response) + worker.PAIR_SUFFIX.encode())

    def test_framing_yields_the_exact_bytes_of_both_documents(self):
        self.assertEqual(worker.pair_documents(self.raw()), [self.questionnaire, self.response])
        tricky = b'{"resourceType":"Questionnaire","text":"},{\\"resource\\":"}'
        self.assertEqual(worker.pair_documents(self.raw(questionnaire=tricky))[0], tricky)
        padded = b"\n " + self.questionnaire + b"\r\n"
        self.assertEqual(worker.pair_documents(self.raw(questionnaire=padded, response=self.response + b"\n")),
                         [padded, self.response + b"\n"])

    def test_validates_both_documents_in_one_process_and_maps_paths(self):
        outcomes = [file_outcome("q"), file_outcome("r", official_issue("error", "Questionnaire_QR_Item_Missing", "QuestionnaireResponse.item[0]"),
                                                    official_issue("warning", "Synthetic", "Questionnaire.item[0]"))]
        with patch.object(self.validator, "pair_outcomes", return_value=outcomes) as run:
            raw = self.raw()
            status, response = self.validator.validate_questionnaire_response(raw)
        run.assert_called_once_with([self.questionnaire, self.response])
        self.assertEqual((status, response["status"], response["purpose"]), (422, "invalid", "questionnaire-response"))
        self.assertEqual(response["sha256"], hashlib.sha256(raw).hexdigest())
        self.assertEqual([item["path"] for item in response["diagnostics"] if item["severity"] != "information"],
                         ["QuestionnaireResponse.item[0]", "Questionnaire.item[0]"])

    def test_unresolved_questionnaire_is_incomplete(self):
        outcomes = [file_outcome("q"), file_outcome("r", official_issue("warning", "Questionnaire_QR_Q_NotFound", "QuestionnaireResponse"))]
        with patch.object(self.validator, "pair_outcomes", return_value=outcomes):
            status, response = self.validator.validate_questionnaire_response(self.raw())
        self.assertEqual((status, response["status"]), (422, "incomplete"))

    def test_rejects_other_shapes_without_running_the_validator(self):
        cases = [
            b'{"x":1,"x":2}',
            json.dumps({"resourceType": "Bundle", "type": "collection", "entry": [{"resource": json.loads(self.questionnaire)},
                                                                                 {"resource": json.loads(self.response)}]}).encode(),
            self.raw(questionnaire=self.response, response=self.questionnaire),
            self.raw(response=b'{"resourceType":"QuestionnaireResponse"}'),
            self.raw()[:-3] + b'}],"id":"x"}',
            worker.PAIR_PREFIX.encode() + self.questionnaire + worker.PAIR_SUFFIX.encode(),
        ]
        with patch.object(self.validator, "pair_outcomes") as run:
            for raw in cases:
                with self.subTest(prefix=raw[:60]):
                    status, response = self.validator.validate_questionnaire_response(raw)
                    self.assertEqual((status, response["status"], response["diagnostics"][0]["rule"]), (422, "invalid", "pair-input"))
            run.assert_not_called()

    def test_validator_failure_is_unavailable(self):
        for error in (OSError("private"), ValueError("private"), subprocess.TimeoutExpired("java", 1)):
            with self.subTest(error=type(error).__name__), patch.object(self.validator, "pair_outcomes", side_effect=error):
                status, response = self.validator.validate_questionnaire_response(self.raw())
                self.assertEqual((status, response["status"], response["diagnostics"]), (503, "unavailable", []))

    def run_pair(self, returncode=0, outcome=None, write=True):
        def run(command, **kwargs):
            paths = [Path(argument) for argument in command if argument.endswith(".json") and "questionnaire" in argument or argument.endswith("2-response.json")]
            self.assertEqual([path.read_bytes() for path in paths], [self.questionnaire, self.response])
            self.assertEqual(kwargs["timeout"], worker.TIMEOUT)
            self.assertIs(kwargs["stdout"], subprocess.DEVNULL)
            self.assertIs(kwargs["stderr"], subprocess.DEVNULL)
            self.assertIn("-no-http-access", command)
            self.assertEqual(command[command.index("-tx") + 1], "n/a")
            output = Path(command[command.index("-output") + 1])
            if write:
                value = outcome(paths) if outcome else {"resourceType": "Bundle", "type": "collection",
                                                        "entry": [{"resource": file_outcome(path)} for path in paths]}
                output.write_text(json.dumps(value))
            return SimpleNamespace(returncode=returncode)
        with patch.object(worker.subprocess, "run", side_effect=run):
            return self.validator.pair_outcomes([self.questionnaire, self.response])

    def test_offline_process_stops_the_engine_and_requires_attributed_outcomes(self):
        outcomes = self.run_pair()
        self.validator.engine.close.assert_called_once()
        self.validator.engine.start.assert_called_once()
        self.assertEqual(len(outcomes), 2)
        error = official_issue("error", "Synthetic", "QuestionnaireResponse")
        self.assertEqual(len(self.run_pair(1, lambda paths: {"resourceType": "Bundle", "entry": [
            {"resource": file_outcome(paths[0])}, {"resource": file_outcome(paths[1], error)}]})), 2)
        failures = [
            dict(returncode=2), dict(write=False), dict(returncode=1),
            dict(outcome=lambda paths: {"resourceType": "Bundle", "entry": [{"resource": file_outcome(paths[1])}, {"resource": file_outcome(paths[0])}]}),
            dict(outcome=lambda paths: {"resourceType": "Bundle", "entry": [{"resource": file_outcome(paths[0])}]}),
            dict(outcome=lambda paths: {"resourceType": "Bundle", "entry": [{"resource": file_outcome(paths[0])},
                                                                            {"resource": {"resourceType": "OperationOutcome", "issue": []}}]}),
        ]
        for failure in failures:
            with self.subTest(failure=failure), self.assertRaises(ValueError):
                self.run_pair(**failure)

    def test_engine_is_restarted_after_every_run_so_health_recovers(self):
        def timeout(*_args, **_kwargs):
            raise subprocess.TimeoutExpired("java", worker.TIMEOUT)
        for outcome in ("success", "unusable", "timeout"):
            with self.subTest(outcome=outcome):
                self.validator.engine = Mock()
                if outcome == "success":
                    self.run_pair()
                elif outcome == "unusable":
                    with self.assertRaises(ValueError):
                        self.run_pair(returncode=2)
                else:
                    with patch.object(worker.subprocess, "run", side_effect=timeout), \
                            self.assertRaises(subprocess.TimeoutExpired):
                        self.validator.pair_outcomes([self.questionnaire, self.response])
                self.assertEqual([name for name, _, _ in self.validator.engine.mock_calls], ["close", "start"])

    def test_failed_engine_restart_does_not_replace_the_result(self):
        self.validator.engine.start.side_effect = ValueError("Engine initialization failed")
        self.assertEqual(len(self.run_pair()), 2)

    def test_framing_breakout_is_refused(self):
        questionnaire = b'{"resourceType":"Questionnaire","meta":{"profile":["' + worker.QUESTIONNAIRE_PROFILE.encode() + b'"]},"title":"abc'
        response = b'"}},{"resource":' + self.response
        with patch.object(self.validator, "pair_outcomes") as run:
            status, result = self.validator.validate_questionnaire_response(self.raw(questionnaire, response))
        self.assertEqual((status, result["status"], result["diagnostics"][0]["rule"]), (422, "invalid", "pair-input"))
        run.assert_not_called()


class DiagnosticTests(unittest.TestCase):
    def test_translation_language_follows_primitive_extensions_only_into_one_translation(self):
        resource = {"item": [{"_text": {"extension": [
            {"url": worker.TRANSLATION, "extension": [{"url": "lang", "valueCode": "ar"}, {"url": "content", "valueString": "x"}]},
            {"url": "other", "extension": [{"url": "lang", "valueCode": "fr"}]},
        ]}}]}
        self.assertEqual(worker.translation_language(resource, "Questionnaire.item[0].text.extension[0]"), "ar")
        self.assertEqual(worker.translation_language(resource, "Questionnaire.item[0].text.extension[0].extension[1]"), "ar")
        coded = {"item": [{"answerOption": [{"valueCoding": {"_display": resource["item"][0]["_text"]}}]}]}
        self.assertEqual(worker.translation_language(
            coded, "Questionnaire.item[0].answerOption[0].value.ofType(Coding).display.extension[0].extension[0].value.ofType(code)"), "ar")
        for path in ("Questionnaire.item[0].text", "Questionnaire.item[0].text.extension[1]", "Questionnaire.item[3]",
                     "Questionnaire.item[x]", "", "Line[1] Col[2]"):
            self.assertIsNone(worker.translation_language(resource, path))

    def test_issue_without_message_id_uses_its_code(self):
        result = worker.issue_diagnostic({"severity": "fatal", "code": "structure", "location": ["Questionnaire"]}, {})
        self.assertEqual((result["severity"], result["rule"], result["path"], result["message"]), ("error", "structure", "Questionnaire", "structure"))


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

    def test_larger_complete_json_and_exact_hard_boundary(self):
        for size in (5 * 1024 * 1024, worker.MAX_BODY):
            raw = b'{"x":"' + b'a' * (size - 8) + b'"}'
            self.assertEqual(len(raw), size)
            self.assertEqual(len(worker.strict_json(raw)["x"]), size - 8)
        with self.assertRaises(worker.InvalidJSON):
            worker.strict_json(raw + b' ')

    def test_accepts_valid_escaping_and_finite_numbers(self):
        value = worker.strict_json(b'{"x":"[\\\"{", "y":1.234, "z":"\\ud83d\\ude00"}')
        self.assertEqual(str(value["y"]), "1.234")
        self.assertEqual(value["z"], "😀")

    def test_event_response_is_digest_bound_and_has_no_input(self):
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



class RecordValidationTests(unittest.TestCase):
    def test_original_number_tokens_reach_identity_validation_and_official_engine(self):
        validator = object.__new__(worker.Validator)
        validator.manifest = {"contractRevision": "pinned"}
        validator.identity = "sha256:pinned"
        validator.adapter_profiles = {"synthetic-profile"}
        validator.engine = Mock()
        raw = b'{"meta":{"profile":["active"]},"value":72.0000,"exponent":1e+02}'
        lossless = object()
        parse = Mock(return_value=lossless)
        graph = Mock()
        error = type("ProducerValidationError", (Exception,), {})
        with patch.dict(worker.sys.modules, {
            "Scripts.canonical_json": SimpleNamespace(loads_lossless=parse),
            "Scripts.producer_validation.context": SimpleNamespace(EXCHANGE_BUNDLE_PROFILE="active", RETRACTION_BUNDLE_PROFILE="retraction"),
            "Scripts.producer_validation.exchange_bundle": SimpleNamespace(
                validate_exchange_bundle=graph, validate_resource_profile_claims=Mock()),
            "Scripts.producer_validation.external_validator": SimpleNamespace(reject_validator_errors=Mock()),
            "Scripts.producer_validation.diagnostics": SimpleNamespace(ProducerValidationError=error),
        }):
            status, response = validator.validate(raw)
        self.assertEqual(status, 200)
        self.assertTrue(response["valid"])
        self.assertEqual(response["sha256"], hashlib.sha256(raw).hexdigest())
        parse.assert_called_once_with(raw)
        self.assertIs(graph.call_args.kwargs["lossless_resource"], lossless)
        self.assertEqual(str(graph.call_args.args[0]["value"]), "72.0000")
        validator.engine.validate.assert_called_once_with(raw)


if __name__ == "__main__":
    unittest.main()
