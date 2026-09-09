"""One offline, digest-bound Grove FHIR validation operation."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import argparse
import hashlib
import http.client
import http.server
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
import time
from decimal import Decimal

MAX_BODY = 4 * 1024 * 1024
MAX_DEPTH = 64
MAX_OUTCOME = 8 * 1024 * 1024
TIMEOUT = 120
ASSETS = Path(os.environ.get("VALIDATOR_ASSETS", "/opt/validator"))


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
            self.engine.start()
        except BaseException:
            self.close()
            raise

    def close(self):
        self.engine.close()
        shutil.rmtree(self.home)

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
            validate_exchange_bundle(resource, "event", self.adapter_profiles)
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
        data = json.dumps(result, separators=(",", ":")).encode("ascii")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        lengths = self.headers.get_all("Content-Length", [])
        if self.path != "/validate" or self.headers.get_all("Transfer-Encoding") or len(lengths) != 1:
            self.send_result(400, {"code": "invalid_request"})
            return
        if len(lengths[0]) > 7 or not lengths[0].isascii() or not lengths[0].isdigit() or not 0 < int(lengths[0]) <= MAX_BODY:
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
        self.send_result(*self.server.validator.validate(raw))

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
    arguments = parser.parse_args()
    # Applies to stdin mode as well as the HTTP handler.
    signal.signal(signal.SIGALRM, Handler.read_timeout)
    try:
        validator = Validator()
    except Exception:
        print("Validator initialization failed.", file=sys.stderr)
        return 2
    try:
        if arguments.stdin:
            status, result = validator.validate(sys.stdin.buffer.read(MAX_BODY + 1))
            print(json.dumps(result, separators=(",", ":")))
            return 0 if status == 200 else 1 if status == 422 else 2
        with Server(("0.0.0.0", 8080), Handler) as server:
            server.validator = validator
            server.serve_forever()
    finally:
        validator.close()


if __name__ == "__main__":
    sys.exit(main())
