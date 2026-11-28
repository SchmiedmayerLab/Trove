"""One offline, digest-bound Grove FHIR validation operation."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import argparse
import hashlib
import http.client
import http.server
import importlib
import json
import os
from pathlib import Path
import resource as process_limits
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from decimal import Decimal

MAX_BODY = 16 * 1024 * 1024
MAX_DEPTH = 64
MAX_OUTCOME = 8 * 1024 * 1024
# Questionnaire replies carry diagnostics; event replies stay below 2 KiB.
MAX_REPLY = 256 * 1024
MAX_DIAGNOSTICS = 100
TIMEOUT = 120
ASSETS = Path(os.environ.get("VALIDATOR_ASSETS", "/opt/validator"))
ROUTES = ("/validate", "/validate/questionnaire", "/validate/questionnaire-response", "/validate/questionnaire-response-structure")
# The response route's exact framing; the server embeds both documents byte for byte.
PAIR_PREFIX = '{"resourceType":"Bundle","type":"collection","entry":[{"resource":'
PAIR_INFIX = '},{"resource":'
PAIR_SUFFIX = '}]}'
FILE_EXTENSION = "http://hl7.org/fhir/StructureDefinition/operationoutcome-file"
# The companion rules use error and warning; any other severity counts as an error.
GROVE_SEVERITIES = {"error": "error", "warning": "warning", "information": "information"}
VALIDATION_LOCK = threading.Lock()
QUESTIONNAIRE_PROFILE = "https://grovealliance.org/fhir/questionnaire/StructureDefinition/grove-questionnaire"
RESPONSE_PROFILE = "https://grovealliance.org/fhir/questionnaire/StructureDefinition/grove-questionnaire-response"
TRANSLATION = "http://hl7.org/fhir/StructureDefinition/translation"
MESSAGE_ID = "http://hl7.org/fhir/StructureDefinition/operationoutcome-message-id"
# Official message identifiers (validator 7.0.6, `-tx n/a`, no network) stating that a check did not run: the
# Questionnaire a response names, an enableWhen condition, a profile the resource declares or depends on, slicing
# cardinality, or a code's membership in a value set or answer options. A code from a code system outside the
# offline package set is reported as information unless a value set check depends on it.
# `Terminology_TX_NoValid_15` is not listed: the validator reports it for the language code of every translation.
NOT_EVALUATED = frozenset({
    "Questionnaire_QR_Q_None",
    "Questionnaire_QR_Q_NotFound",
    "Questionnaire_QR_Item_EnableWhen_Uncheckable",
    "QUESTIONNAIRE_QR_ITEM_BADOPTION_CS",
    "Validation_VAL_Profile_Unknown",
    "VALIDATION_VAL_PROFILE_UNKNOWN_ERROR",
    "VALIDATION_VAL_PROFILE_UNKNOWN_ERROR_NETWORK",
    "VALIDATION_VAL_PROFILE_UNKNOWN_NOT_POLICY",
    "VALIDATION_VAL_GLOBAL_PROFILE_UNKNOWN",
    "VALIDATION_VAL_PROFILE_DEPENDS_NOT_RESOLVED",
    "Validation_VAL_Profile_NoCheckMin_one",
    "Validation_VAL_Profile_NoCheckMin_other",
    "Validation_VAL_Profile_NoCheckMax_one",
    "Validation_VAL_Profile_NoCheckMax_other",
    "Reference_REF_CantResolveProfile",
    "TERMINOLOGY_TX_NOSVC_BOUND_REQ",
    "Terminology_TX_Binding_NoServer",
    "Terminology_TX_Binding_CantCheck",
    "Terminology_TX_ValueSet_NotFound",
    "Error_validating_code_running_without_terminology_services",
    "Unable_to_resolve_value_Set_",
    "UNABLE_TO_CHECK_IF_THE_PROVIDED_CODES_ARE_IN_THE_VALUE_SET_",
    "UNABLE_TO_CHECK_IF_THE_PROVIDED_CODES_ARE_IN_THE_VALUE_SET_CS",
    "UNABLE_TO_CHECK_IF_THE_PROVIDED_CODES_ARE_IN_THE_VALUE_SET_VS",
})
# The structure route validates a response without its Questionnaire, which the engine cannot resolve. The server
# checks the response against the exact published Questionnaire bytes with Grove's pair rules.
PAIR_ONLY = frozenset({"Questionnaire_QR_Q_NotFound"})


def bound_child_output():
    process_limits.setrlimit(process_limits.RLIMIT_FSIZE, (16 * 1024 * 1024, 16 * 1024 * 1024))


def outcome_has_valid_issues(outcome):
    issues = outcome.get("issue")
    return isinstance(issues, list) and bool(issues) and all(
        isinstance(issue, dict) and issue.get("severity") in ("fatal", "error", "warning", "information")
        for issue in issues
    )


class InvalidJSON(ValueError):
    """A serialization outside the bounded input contract."""


def strict_json(raw, maximum=MAX_BODY):
    if not raw or len(raw) > maximum or raw.startswith(b"\xef\xbb\xbf"):
        raise InvalidJSON()
    text = raw.decode("utf-8", errors="strict")
    depth = 0
    quoted = escaped = False
    for character in text:
        if quoted:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                quoted = False
        elif character == '"':
            quoted = True
        elif character in "[{":
            depth += 1
            if depth > MAX_DEPTH:
                raise InvalidJSON()
        elif character in "]}":
            depth -= 1

    def pairs(values):
        result = {}
        for key, value in values:
            if key in result:
                raise InvalidJSON()
            result[key] = value
        return result

    def constant(_):
        raise InvalidJSON()

    def number(value):
        result = Decimal(value)
        if not result.is_finite() or abs(result.adjusted()) > 308:
            raise InvalidJSON()
        return result

    result = json.loads(text, object_pairs_hook=pairs, parse_float=number, parse_constant=constant)

    def strings(value):
        if isinstance(value, str):
            value.encode("utf-8", errors="strict")
        elif isinstance(value, dict):
            for key, item in value.items():
                strings(key)
                strings(item)
        elif isinstance(value, list):
            for item in value:
                strings(item)

    strings(result)
    return result


def diagnostic(severity, source, rule, path, message, language=None):
    """One bounded finding. Paths and messages can quote submitted content, never process output."""
    result = {
        "severity": severity,
        "source": source,
        "rule": str(rule)[:200],
        "path": str(path)[:500],
        "message": str(message)[:1000],
    }
    if isinstance(language, str) and language:
        result["language"] = language[:100]
    return result


def path_steps(path):
    """`Questionnaire.item[0].value.ofType(Coding)` as [("item", 0), ("valueCoding", None)], without the resource type."""
    steps = []
    for part in path.replace(".ofType(", "ofType(").split(".")[1:]:
        name, _, index = part.partition("[")
        name, _, choice = name.partition("ofType(")
        if choice:
            if not choice.endswith(")") or not choice[:-1].isalnum():
                return None
            name += choice[0].upper() + choice[1:-1]
        if not name or (index and not index[:-1].isdigit()):
            return None
        steps.append((name, int(index[:-1]) if index else None))
    return steps


def translation_language(resource, path):
    """The `lang` of the translation extension a FHIRPath points into, if any.

    A primitive's extensions are serialized under `_name`, where a step continues past a primitive value.
    """
    steps = path_steps(path) if isinstance(path, str) else None
    node = resource
    for name, index in steps or ():
        if not isinstance(node, dict):
            return None
        value = node.get(name)
        if not isinstance(value, (dict, list)):
            value = node.get("_" + name)
        if index is not None:
            value = value[index] if isinstance(value, list) and index < len(value) else None
        node = value
        if isinstance(node, dict) and node.get("url") == TRANSLATION:
            parts = node.get("extension")
            languages = [part.get("valueCode") for part in parts if isinstance(part, dict) and part.get("url") == "lang"] \
                if isinstance(parts, list) else []
            return languages[0] if len(languages) == 1 and isinstance(languages[0], str) else None
    return None


def issue_diagnostic(issue, resources):
    """Map one official issue. `resources` maps a FHIRPath prefix to (resource type, resource)."""
    identifiers = [extension.get("valueCode") or extension.get("valueString") for extension in issue.get("extension", [])
                   if isinstance(extension, dict) and extension.get("url") == MESSAGE_ID]
    rule = identifiers[0] if identifiers and isinstance(identifiers[0], str) else issue.get("code") or "unknown"
    paths = [value for field in ("expression", "location") for value in (issue.get(field) or []) if isinstance(value, str)]
    path = paths[0] if paths else ""
    resource = None
    for prefix, (resource_type, value) in resources.items():
        if path == prefix or path.startswith(prefix + ".") or path.startswith(prefix + "/*"):
            remainder = path[len(prefix):]
            if remainder.startswith("/*"):
                remainder = remainder.partition("*/")[2]
            path, resource = resource_type + remainder, value
            break
    details = issue.get("details")
    message = issue.get("diagnostics") or (details.get("text") if isinstance(details, dict) else None) or rule
    severity = "error" if issue["severity"] in ("fatal", "error") else issue["severity"]
    return diagnostic(severity, "fhir", rule, path, message, translation_language(resource, path) if resource else None)


def assessed(diagnostics, not_evaluated=False):
    if any(item["severity"] == "error" for item in diagnostics):
        return "invalid"
    return "incomplete" if not_evaluated else "valid"


class Engine:
    """One loopback-only official engine; no client-selected routes or configuration."""

    def __init__(self, assets, manifest, home):
        self.assets, self.manifest, self.home = assets, manifest, home
        self.process = None
        self.port = None

    @property
    def ready(self):
        return self.port is not None and self.process is not None and self.process.poll() is None

    def close(self):
        process = self.process
        self.port = None
        if process is not None:
            if process.poll() is None:
                try:
                    process.terminate()
                except ProcessLookupError:
                    pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            self.process = None

    def start(self):
        self.close()
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            self.port = reservation.getsockname()[1]
        command = ["java", "-Xmx1400m", "-Djava.net.preferIPv4Stack=true", f"-Duser.home={self.home}",
                   "-jar", str(self.assets / "validator_cli.jar"), "server", str(self.port),
                   "-version", "4.0.1", "-tx", "n/a", "-no-http-access"]
        for package in self.manifest["guides"]:
            command.extend(("-ig", str(self.assets / "packages" / package["file"])))
        try:
            self.process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                            stderr=subprocess.DEVNULL, preexec_fn=bound_child_output)
            deadline = time.monotonic() + TIMEOUT
            while self.ready and time.monotonic() < deadline:
                connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=min(2, deadline - time.monotonic()))
                try:
                    # The official route is POST-only. This proves the loaded service
                    # is listening, not that any participant payload is valid.
                    connection.request("GET", "/validateResource")
                    response = connection.getresponse()
                    if response.status == 405 and response.read(64) == b"Method not allowed" and self.ready:
                        return
                except (OSError, http.client.HTTPException):
                    pass
                finally:
                    connection.close()
                time.sleep(0.1)
            raise ValueError("Engine initialization failed")
        except BaseException:
            self.close()
            raise

    def validate(self, raw):
        # Handler installs the alarm callback; use one absolute budget across
        # restart, request headers and body, not a renewable socket-read timeout.
        signal.alarm(TIMEOUT)
        try:
            if not self.ready:
                self.start()
            connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=TIMEOUT)
            try:
                connection.request("POST", "/validateResource", body=raw,
                                   headers={"Content-Type": "application/fhir+json", "Accept": "application/fhir+json"})
                response = connection.getresponse()
                if response.status != 200:
                    raise ValueError("Engine response unavailable")
                outcome = strict_json(response.read(MAX_OUTCOME + 1), maximum=MAX_OUTCOME)
            finally:
                connection.close()
            if not isinstance(outcome, dict) or outcome.get("resourceType") != "OperationOutcome" or not outcome_has_valid_issues(outcome):
                raise ValueError("Engine outcome unavailable")
            return outcome
        except BaseException:
            # Never reuse a hung, terminated or malformed-response engine. The
            # failed request returns unavailable; a later request may start afresh.
            self.close()
            raise
        finally:
            signal.alarm(0)


class Validator:
    def __init__(self, assets=ASSETS):
        self.assets = assets
        manifest_bytes = (assets / "manifest.json").read_bytes()
        self.manifest = json.loads(manifest_bytes)
        self.identity = "sha256:" + hashlib.sha256(manifest_bytes).hexdigest()
        if hashlib.sha256(Path(__file__).read_bytes()).hexdigest() != self.manifest["workerSHA256"]:
            raise ValueError("Worker checksum mismatch")
        # Context preparation verifies every source, JAR and package against this manifest.
        # Runtime assets are immutable; requests cannot select packages, profiles or tools.
        self.home = Path(tempfile.mkdtemp(prefix="validator-home-"))
        self.engine = Engine(assets, self.manifest, self.home)
        try:
            shutil.copytree(assets / "cache", self.home / ".fhir" / "packages")
            sys.path.insert(0, str(assets / "grove-fhir"))
            from Scripts.producer_validation.context import ADAPTER_PACKAGE_PROFILES
            self.adapter_profiles = set().union(*ADAPTER_PACKAGE_PROFILES.values())
            self.questionnaire_rules = importlib.import_module("Scripts.validate-questionnaire").validate_questionnaire
            self.engine.start()
        except BaseException:
            self.close()
            raise

    def close(self):
        self.engine.close()
        shutil.rmtree(self.home)

    def route(self, path):
        """The one validation each fixed route performs; routes never select each other's checks."""
        return dict(zip(ROUTES, (self.validate, self.validate_questionnaire, self.validate_questionnaire_response,
                                 self.validate_response_structure)))[path]

    def respond(self, path, raw, deliver, restore=True):
        """Validate, deliver the result, then start a stopped engine before any other request runs.

        One validation at a time: the response route stops the shared engine, so no other validation may
        use it until it is started again. The HTTP server is single-threaded as well; this does not rely on it.
        The result is delivered before the restart, so a client never waits for the engine to start.
        """
        with VALIDATION_LOCK:
            try:
                deliver(*self.route(path)(raw))
            finally:
                if restore and not self.engine.ready:
                    self.restart_engine()

    def response(self, raw, valid=False, code=None):
        result = {
            "valid": valid,
            "sha256": hashlib.sha256(raw).hexdigest(),
            "contractRevision": self.manifest["contractRevision"],
            "validatorIdentity": self.identity,
        }
        if code:
            result["code"] = code
        return result

    def validate(self, raw):
        from Scripts.canonical_json import loads_lossless
        from Scripts.producer_validation.context import EXCHANGE_BUNDLE_PROFILE, RETRACTION_BUNDLE_PROFILE
        from Scripts.producer_validation.exchange_bundle import validate_exchange_bundle, validate_resource_profile_claims
        from Scripts.producer_validation.external_validator import reject_validator_errors
        from Scripts.producer_validation.diagnostics import ProducerValidationError
        try:
            resource = strict_json(raw)
        except (ValueError, UnicodeError, RecursionError):
            return 422, self.response(raw, code="invalid_json")
        try:
            profiles = resource.get("meta", {}).get("profile", []) if isinstance(resource, dict) else []
            if not isinstance(profiles, list) or not any(
                profile in (EXCHANGE_BUNDLE_PROFILE, RETRACTION_BUNDLE_PROFILE) for profile in profiles
            ):
                raise ProducerValidationError("exchange profile required")
            validate_resource_profile_claims(resource, "event", self.adapter_profiles)
            # Content identities depend on the original number lexemes, including trailing
            # zeros and exponent spelling; the semantic Decimal tree cannot supply those.
            validate_exchange_bundle(resource, "event", self.adapter_profiles, lossless_resource=loads_lossless(raw))
        except (ProducerValidationError, ValueError, TypeError, KeyError, AttributeError, RecursionError):
            return 422, self.response(raw, code="invalid_fhir")
        try:
            outcome = self.engine.validate(raw)
            try:
                reject_validator_errors(outcome, "event")
            except ProducerValidationError:
                return 422, self.response(raw, code="invalid_fhir")
            return 200, self.response(raw, valid=True)
        except (OSError, ValueError, http.client.HTTPException, subprocess.SubprocessError):
            return 503, self.response(raw, code="validator_unavailable")

    def validate_response_structure(self, raw):
        """Validate one Grove QuestionnaireResponse with the reusable engine, without its Questionnaire.

        Admission of a participant's task response uses this route; its reply has the exchange route's shape and
        no diagnostics.
        """
        purpose = "questionnaire-response-structure"
        try:
            resource = strict_json(raw)
        except (ValueError, UnicodeError, RecursionError):
            return 422, dict(self.response(raw, code="invalid_json"), purpose=purpose)
        if not self.claims(resource, "QuestionnaireResponse", RESPONSE_PROFILE):
            return 422, dict(self.response(raw, code="invalid_fhir"), purpose=purpose)
        try:
            outcome = self.engine.validate(raw)
        except (OSError, ValueError, http.client.HTTPException, subprocess.SubprocessError):
            return 503, dict(self.response(raw, code="validator_unavailable"), purpose=purpose)
        errors = [item for item in (issue_diagnostic(issue, {}) for issue in outcome["issue"])
                  if item["severity"] == "error" and item["rule"] not in PAIR_ONLY]
        if any(item["rule"] in NOT_EVALUATED for item in errors):
            # A check the engine could not run establishes neither validity nor a rejection of the answers.
            return 503, dict(self.response(raw, code="validator_unavailable"), purpose=purpose)
        if errors:
            return 422, dict(self.response(raw, code="invalid_fhir"), purpose=purpose)
        return 200, dict(self.response(raw, valid=True), purpose=purpose)

    def report(self, raw, purpose, status, diagnostics=()):
        """An authoring result with its findings, errors first, bounded in count and size."""
        order = {"error": 0, "warning": 1, "information": 2}
        diagnostics = sorted(diagnostics, key=lambda item: order[item["severity"]])
        result = {
            "status": status,
            "sha256": hashlib.sha256(raw).hexdigest(),
            "contractRevision": self.manifest["contractRevision"],
            "validatorIdentity": self.identity,
            "purpose": purpose,
            "diagnostics": diagnostics[:MAX_DIAGNOSTICS],
        }
        while len(json.dumps(result, ensure_ascii=False).encode()) > MAX_REPLY - 64:
            result["diagnostics"].pop()
        if len(result["diagnostics"]) < len(diagnostics):
            result["omittedDiagnostics"] = len(diagnostics) - len(result["diagnostics"])
        return {"valid": 200, "unavailable": 503}.get(status, 422), result

    @staticmethod
    def claims(resource, resource_type, profile):
        profiles = resource.get("meta", {}).get("profile", []) if isinstance(resource, dict) else []
        return isinstance(resource, dict) and resource.get("resourceType") == resource_type \
            and isinstance(profiles, list) and profile in profiles

    def official(self, raw, resources):
        """Official findings, and whether any states that a check was skipped. Raises when unavailable."""
        outcome = self.engine.validate(raw)
        diagnostics = [issue_diagnostic(issue, resources) for issue in outcome["issue"]]
        return diagnostics, any(item["rule"] in NOT_EVALUATED for item in diagnostics)

    def validate_questionnaire(self, raw):
        """Validate authoring content without broadening the exchange admission route."""
        purpose = "questionnaire"
        try:
            resource = strict_json(raw)
        except (ValueError, UnicodeError, RecursionError):
            return self.report(raw, purpose, "invalid", [diagnostic(
                "error", "trove", "invalid-json", "", "The resource is not JSON within the validation limits.")])
        if not self.claims(resource, "Questionnaire", QUESTIONNAIRE_PROFILE):
            return self.report(raw, purpose, "invalid", [diagnostic(
                "error", "trove", "profile-required", "Questionnaire.meta.profile",
                "The resource must be a Questionnaire that claims the Grove Questionnaire profile.")])
        try:
            diagnostics = [diagnostic(GROVE_SEVERITIES.get(issue.severity, "error"), "grove", issue.rule, issue.path, issue.message,
                                      translation_language(resource, issue.path)) for issue in self.questionnaire_rules(resource)]
        except (ValueError, TypeError, KeyError, AttributeError, RecursionError):
            diagnostics = [diagnostic("error", "grove", "questionnaire-rules", "Questionnaire",
                                      "The Grove Questionnaire rules cannot read this resource.")]
        try:
            official, not_evaluated = self.official(raw, {"Questionnaire": ("Questionnaire", resource)})
        except (OSError, ValueError, http.client.HTTPException, subprocess.SubprocessError):
            # A definite rule failure stays invalid; otherwise nothing establishes validity.
            return self.report(raw, purpose, "invalid" if assessed(diagnostics) == "invalid" else "unavailable", diagnostics)
        diagnostics += official
        return self.report(raw, purpose, assessed(diagnostics, not_evaluated), diagnostics)

    def validate_questionnaire_response(self, raw):
        """Validate one response against its exact Questionnaire with the official validator.

        The engine's single-resource route cannot resolve a study's Questionnaire, so one offline
        validator process loads both documents into its context. The input is a collection Bundle
        framed exactly as the server builds it, so each document's original bytes are validated.
        """
        purpose = "questionnaire-response"
        try:
            documents = pair_documents(raw)
            resources = [strict_json(document) for document in documents]
        except (ValueError, UnicodeError, RecursionError):
            return self.report(raw, purpose, "invalid", [diagnostic(
                "error", "trove", "pair-input", "", "The input must be a collection Bundle of a Grove Questionnaire and a "
                "Grove QuestionnaireResponse, framed exactly as documented.")])
        if not (self.claims(resources[0], "Questionnaire", QUESTIONNAIRE_PROFILE)
                and self.claims(resources[1], "QuestionnaireResponse", RESPONSE_PROFILE)):
            return self.report(raw, purpose, "invalid", [diagnostic(
                "error", "trove", "pair-input", "", "The input must be a collection Bundle of a Grove Questionnaire and a "
                "Grove QuestionnaireResponse, framed exactly as documented.")])
        try:
            outcomes = self.pair_outcomes(documents)
        except (OSError, ValueError, TypeError, KeyError, RecursionError, subprocess.SubprocessError):
            return self.report(raw, purpose, "unavailable")
        named = {"Questionnaire": ("Questionnaire", resources[0]), "QuestionnaireResponse": ("QuestionnaireResponse", resources[1])}
        diagnostics = [issue_diagnostic(issue, named) for outcome in outcomes for issue in outcome["issue"]]
        return self.report(raw, purpose, assessed(diagnostics, any(item["rule"] in NOT_EVALUATED for item in diagnostics)),
                           diagnostics)

    def pair_outcomes(self, documents):
        """One offline validator process over both documents; raises unless its outcomes are trustworthy.

        The reusable engine is stopped first so that both Java processes never share the memory limit;
        `respond` starts it again after the result is delivered.
        """
        self.engine.close()
        return self.run_pair(documents)

    def restart_engine(self):
        """Start the reusable engine; on failure the next request starts it, and `/health` reports it unready."""
        try:
            self.engine.start()
        except (OSError, ValueError, TimeoutError, subprocess.SubprocessError):
            pass

    def run_pair(self, documents):
        with tempfile.TemporaryDirectory(prefix="validator-pair-") as directory:
            paths = [Path(directory) / "1-questionnaire.json", Path(directory) / "2-response.json"]
            for path, document in zip(paths, documents):
                path.write_bytes(document)
            output = Path(directory) / "outcome.json"
            command = ["java", "-Xmx1400m", "-Djava.net.preferIPv4Stack=true", f"-Duser.home={self.home}",
                       "-jar", str(self.assets / "validator_cli.jar"), *map(str, paths),
                       "-version", "4.0.1", "-tx", "n/a", "-no-http-access", "-output", str(output)]
            for package in self.manifest["guides"]:
                command.extend(("-ig", str(self.assets / "packages" / package["file"])))
            result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    preexec_fn=bound_child_output, timeout=TIMEOUT, check=False)
            if result.returncode not in (0, 1) or not output.is_file() or output.is_symlink():
                raise ValueError("Validator result unavailable")
            with output.open("rb") as file:
                value = strict_json(file.read(MAX_OUTCOME + 1), maximum=MAX_OUTCOME)
            entries = value.get("entry") if isinstance(value, dict) and value.get("resourceType") == "Bundle" else None
            outcomes = [entry.get("resource") for entry in entries if isinstance(entry, dict)] if isinstance(entries, list) else []
            if len(outcomes) != 2 or not all(
                isinstance(outcome, dict) and outcome.get("resourceType") == "OperationOutcome" and outcome_has_valid_issues(outcome)
                and [extension.get("valueString") for extension in outcome.get("extension", [])
                     if isinstance(extension, dict) and extension.get("url") == FILE_EXTENSION] == [str(path)]
                for outcome, path in zip(outcomes, paths)
            ):
                raise ValueError("Validator result unavailable")
            errors = any(issue["severity"] in ("fatal", "error") for outcome in outcomes for issue in outcome["issue"])
            if result.returncode == 1 and not errors:
                raise ValueError("Validator result unavailable")
            return outcomes


def pair_documents(raw):
    """The exact Questionnaire and response bytes of a pair Bundle, including surrounding whitespace; raises unless
    framed exactly."""
    strict_json(raw)
    text = raw.decode("utf-8", errors="strict")
    if not text.startswith(PAIR_PREFIX) or not text.endswith(PAIR_SUFFIX):
        raise ValueError("pair framing")
    decoder = json.JSONDecoder()
    whitespace = " \t\n\r"

    def document(start):
        _, end = decoder.raw_decode(text, len(text) - len(text[start:].lstrip(whitespace)))
        return len(text) - len(text[end:].lstrip(whitespace))

    middle = document(len(PAIR_PREFIX))
    if not text.startswith(PAIR_INFIX, middle):
        raise ValueError("pair framing")
    end = document(middle + len(PAIR_INFIX))
    if end != len(text) - len(PAIR_SUFFIX):
        raise ValueError("pair framing")
    return [text[len(PAIR_PREFIX):middle].encode(), text[middle + len(PAIR_INFIX):end].encode()]


class Handler(http.server.BaseHTTPRequestHandler):
    # Deliberately single-process/single-request: no unbounded threads or Java processes.
    protocol_version = "HTTP/1.0"

    def setup(self):
        super().setup()
        self.connection.settimeout(10)
        # This server is deliberately single-threaded. Bound the *whole* header/body
        # read, rather than letting a slow sender renew a socket timeout indefinitely.
        signal.signal(signal.SIGALRM, self.read_timeout)
        signal.alarm(10)

    @staticmethod
    def read_timeout(signum, frame):
        raise TimeoutError()

    def finish(self):
        signal.alarm(0)
        super().finish()

    def log_message(self, *args):
        pass

    def send_error(self, code, message=None, explain=None):
        self.send_result(code, {"code": "invalid_request"})

    def send_result(self, status, result):
        data = json.dumps(result, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()

    def do_POST(self):
        lengths = self.headers.get_all("Content-Length", [])
        if self.path not in ROUTES or self.headers.get_all("Transfer-Encoding") or len(lengths) != 1:
            self.send_result(400, {"code": "invalid_request"})
            return
        if len(lengths[0]) > len(str(MAX_BODY)) or not lengths[0].isascii() or not lengths[0].isdigit() or not 0 < int(lengths[0]) <= MAX_BODY:
            self.send_result(413, {"code": "invalid_request"})
            return
        if self.headers.get_all("Content-Type") != ["application/fhir+json"]:
            self.send_result(415, {"code": "invalid_request"})
            return
        deadline = time.monotonic() + 10
        chunks = []
        remaining = int(lengths[0])
        while remaining:
            available = deadline - time.monotonic()
            if available <= 0:
                self.send_result(408, {"code": "invalid_request"})
                return
            self.connection.settimeout(available)
            chunk = self.rfile.read1(min(remaining, 65536))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
        if len(raw) != int(lengths[0]):
            self.send_result(400, {"code": "invalid_request"})
            return
        signal.alarm(0)
        self.server.validator.respond(self.path, raw, self.send_result)

    def do_GET(self):
        ready = self.path == "/health" and self.server.validator.engine.ready
        self.send_result((200 if ready else 503) if self.path == "/health" else 404, {"ready": ready})


class Server(http.server.HTTPServer):
    request_queue_size = 2

    def handle_error(self, request, client_address):
        # Never print arbitrary parser exceptions or request content to process logs.
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stdin", action="store_true")
    purpose = parser.add_mutually_exclusive_group()
    purpose.add_argument("--questionnaire", action="store_true", help="validate a Questionnaire in stdin mode")
    purpose.add_argument("--questionnaire-response", action="store_true",
                         help="validate a Bundle of a Questionnaire and its QuestionnaireResponse in stdin mode")
    purpose.add_argument("--questionnaire-response-structure", action="store_true",
                         help="validate one QuestionnaireResponse without its Questionnaire in stdin mode")
    arguments = parser.parse_args()
    if (arguments.questionnaire or arguments.questionnaire_response or arguments.questionnaire_response_structure) \
            and not arguments.stdin:
        parser.error("--questionnaire, --questionnaire-response and --questionnaire-response-structure require --stdin")
    # Applies to stdin mode as well as the HTTP handler.
    signal.signal(signal.SIGALRM, Handler.read_timeout)
    try:
        validator = Validator()
    except Exception:
        print("Validator initialization failed.", file=sys.stderr)
        return 2
    try:
        if arguments.stdin:
            route = ROUTES[3] if arguments.questionnaire_response_structure else ROUTES[2] if arguments.questionnaire_response \
                else ROUTES[1] if arguments.questionnaire else ROUTES[0]
            replies = []
            validator.respond(route, sys.stdin.buffer.read(MAX_BODY + 1), lambda *reply: replies.append(reply), restore=False)
            status, result = replies[0]
            print(json.dumps(result, separators=(",", ":"), ensure_ascii=False))
            return 0 if status == 200 else 1 if status == 422 else 2
        with Server(("0.0.0.0", 8080), Handler) as server:
            server.validator = validator
            server.serve_forever()
    finally:
        validator.close()


if __name__ == "__main__":
    sys.exit(main())
