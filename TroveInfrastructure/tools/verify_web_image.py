# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

"""Verify the built dashboard image with disposable certificates, containers and networking."""

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
from ipaddress import ip_address
import json
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID


TRAEFIK = "traefik:v3.5.0@sha256:4e7175cfe19be83c6b928cae49dde2f2788fb307189a4dc9550b67acf30c11a5"
SETTINGS = {"VITE_API_BASE_PATH": "https://localhost", "VITE_KEYCLOAK_URL": "https://localhost/auth",
            "VITE_KEYCLOAK_REALM": "synthetic-realm", "VITE_KEYCLOAK_CLIENT_ID": "synthetic-web"}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def command(*args, timeout=60):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=timeout).stdout.strip()


class Certificates:
    def __init__(self, root):
        self.root = root
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Synthetic Web Test CA")])
        now = datetime.now(timezone.utc)
        self.ca = (x509.CertificateBuilder().subject_name(self.name).issuer_name(self.name).public_key(self.key.public_key())
                   .serial_number(x509.random_serial_number()).not_valid_before(now - timedelta(days=1))
                   .not_valid_after(now + timedelta(days=2))
                   .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
                   .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, None, None), critical=True)
                   .add_extension(x509.SubjectKeyIdentifier.from_public_key(self.key.public_key()), critical=False)
                   .sign(self.key, hashes.SHA256()))
        self.ca_file = root / "ca.pem"
        self.ca_file.write_bytes(self.ca.public_bytes(serialization.Encoding.PEM))

    def identity(self, name, *, hostname="localhost", expired=False, mismatch=False, encrypted=False):
        directory = self.root / name
        directory.mkdir(mode=0o755, exist_ok=True)
        # Only synthetic leaf identities are mounted into unprivileged containers.
        directory.chmod(0o755)
        key = ec.generate_private_key(ec.SECP256R1())
        now = datetime.now(timezone.utc)
        certificate = (x509.CertificateBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, hostname)]))
                       .issuer_name(self.name).public_key(key.public_key()).serial_number(x509.random_serial_number())
                       .not_valid_before(now - timedelta(days=2)).not_valid_after(now + timedelta(days=-1 if expired else 1))
                       .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
                       .add_extension(x509.KeyUsage(True, False, False, False, False, False, False, None, None), critical=True)
                       .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(self.key.public_key()), critical=False)
                       .add_extension(x509.SubjectAlternativeName([x509.DNSName(hostname), *(
                           [x509.IPAddress(ip_address("127.0.0.1"))] if hostname == "localhost" else [])]), critical=False)
                       .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
                       .sign(self.key, hashes.SHA256()))
        (directory / "tls.crt").write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
        signing_key = ec.generate_private_key(ec.SECP256R1()) if mismatch else key
        encryption = serialization.BestAvailableEncryption(b"synthetic-test-password") if encrypted else serialization.NoEncryption()
        (directory / "tls.key").write_bytes(signing_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, encryption))
        for file in directory.iterdir():
            file.chmod(0o644)
        return directory


class Verification:
    def __init__(self, image, output, fixtures):
        self.image, self.output, self.fixtures = image, output, fixtures
        self.name = "trove-web-proof-" + uuid.uuid4().hex[:12]
        self.containers = []
        self.network = False
        self.results = {"image": json.loads(command("docker", "image", "inspect", image))[0]["Id"], "checks": [], "passed": False}
        self.context = ssl.create_default_context(cafile=str(fixtures.ca_file))

    def container(self, name, *, identity=None, environment=None, image=None, arguments=(), mounts=(), serving=True):
        options = ["docker", "create", "--name", self.name + "-" + name, "--network", self.name,
                   "--network-alias", name, "--memory", "256m", "--cpus", "1"]
        if serving:
            options += ["-p", "127.0.0.1::8080"]
        if image is None:
            options += ["--read-only", "--tmpfs", "/var/cache/nginx:uid=101,gid=101,mode=0700,size=16m",
                        "--cap-drop", "ALL", "--security-opt", "no-new-privileges"]
        for key, value in {**SETTINGS, **(environment or {})}.items():
            options += ["--env", key + "=" + value]
        if identity:
            options += ["--mount", f"type=bind,source={identity},target=/run/secrets/https,readonly"]
        for source, target in mounts:
            options += ["--mount", f"type=bind,source={source},target={target},readonly"]
        identifier = command(*options, image or self.image, *arguments)
        self.containers.append((name, identifier))
        command("docker", "start", identifier)
        if not serving:
            return identifier, None
        port = int(command("docker", "port", identifier, "8080/tcp").rsplit(":", 1)[1])
        return identifier, port

    def fetch(self, port, path="/", *, secure=True, headers=None):
        request = urllib.request.Request(f"{'https' if secure else 'http'}://localhost:{port}{path}", headers=headers or {})
        with urllib.request.urlopen(request, context=self.context, timeout=3) as response:
            return response.status, response.headers, response.read(10_000_001)

    def ready(self, identifier, port, *, secure=True):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            require(command("docker", "inspect", "-f", "{{.State.Running}}", identifier) == "true", "Web container exited before readiness")
            try:
                if self.fetch(port, secure=secure)[0] == 200:
                    return
            except (OSError, urllib.error.URLError):
                pass
            time.sleep(0.1)
        raise RuntimeError("Web image did not become ready")

    def check_content(self, port, *, secure):
        _, _, index = self.fetch(port, secure=secure)
        for path in ("/index.html", "/studies/synthetic-study"):
            _, headers, body = self.fetch(port, path, secure=secure)
            require(body == index and "no-store" in headers.get("Cache-Control", ""), "SPA fallback or HTML cache policy changed")
        _, headers, settings = self.fetch(port, "/env.js", secure=secure)
        require("no-store" in headers.get("Cache-Control", ""), "Runtime configuration is cacheable")
        decoded = subprocess.run(["node", "--input-type=module", "-e",
                                  "import fs from 'node:fs'; import vm from 'node:vm'; const c={window:{}}; vm.runInNewContext(fs.readFileSync(0,'utf8'),c); console.log(JSON.stringify(c.window.__ENV__));"],
                                 input=settings, capture_output=True, timeout=10, check=True)
        require(json.loads(decoded.stdout) == SETTINGS, "Runtime settings changed")
        asset = re.search(rb'src="(/assets/[^\"]+\.js)"', index)
        require(asset is not None, "Built application script is missing")
        _, headers, body = self.fetch(port, asset[1].decode(), secure=secure)
        cache_control = ", ".join(headers.get_all("Cache-Control", []))
        require(len(body) > 0 and "immutable" in cache_control, "Application asset or cache policy changed")
        sentinel = "synthetic-sensitive-value"
        try:
            self.fetch(port, "/missing-" + sentinel + ".js?code=" + sentinel, secure=secure,
                       headers={"Authorization": "Bearer " + sentinel, "Cookie": "session=" + sentinel})
        except urllib.error.HTTPError as error:
            require(error.code == 404, "Unexpected missing-asset status")
        else:
            raise RuntimeError("Missing asset unexpectedly returned successful content")

    def startup_failure(self, name, *, identity=None, environment=None):
        identifier, _ = self.container(name, identity=identity, environment=environment, serving=False)
        require(command("docker", "wait", identifier, timeout=15) != "0", "Invalid configuration exited successfully")
        self.results["checks"].append(name)

    def certificate_failure(self, name, identity):
        identifier, port = self.container(name, identity=identity)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            require(command("docker", "inspect", "-f", "{{.State.Running}}", identifier) == "true", "Certificate case did not serve TLS")
            try:
                self.fetch(port)
            except urllib.error.URLError as error:
                if isinstance(error.reason, ssl.SSLCertVerificationError):
                    self.results["checks"].append(name)
                    return
            time.sleep(0.1)
        raise RuntimeError("Untrusted certificate was not rejected")

    def fingerprint(self, port):
        with socket.create_connection(("127.0.0.1", port), timeout=3) as connection:
            with self.context.wrap_socket(connection, server_hostname="localhost") as secured:
                return hashlib.sha256(secured.getpeercert(binary_form=True)).hexdigest()

    def exercise(self):
        command("docker", "network", "create", self.name)
        self.network = True
        valid = self.fixtures.identity("valid")
        self.startup_failure("missing-identity")
        partial = self.fixtures.identity("partial")
        (partial / "tls.key").unlink()
        self.startup_failure("missing-key", identity=partial)
        malformed = self.fixtures.identity("malformed")
        (malformed / "tls.crt").write_text("not a certificate")
        self.startup_failure("malformed-certificate", identity=malformed)
        self.startup_failure("invalid-mode", identity=valid, environment={"APP_ENVIRONMENT": "invalid"})
        self.startup_failure("empty-mode", identity=valid, environment={"APP_ENVIRONMENT": ""})
        self.startup_failure("mismatched-key", identity=self.fixtures.identity("mismatch", mismatch=True))
        self.startup_failure("encrypted-key", identity=self.fixtures.identity("encrypted", encrypted=True))
        self.certificate_failure("expired", self.fixtures.identity("expired", expired=True))
        self.certificate_failure("wrong-host", self.fixtures.identity("wrong", hostname="wrong.example.test"))
        other_root = self.fixtures.root / "other-ca"
        other_root.mkdir()
        self.certificate_failure("unknown-ca", Certificates(other_root).identity("unknown"))
        web, port = self.container("web", identity=valid)
        self.ready(web, port)
        require(command("docker", "exec", web, "id", "-u") == "101", "Web image is not running as the expected non-root user")
        self.check_content(port, secure=True)
        try:
            self.fetch(port, secure=False)
        except (OSError, urllib.error.URLError):
            pass
        else:
            raise RuntimeError("Production served plaintext dashboard content")
        self.results["checks"].append("production-https-content-and-plaintext-rejection")
        first = self.fingerprint(port)
        self.fixtures.identity("valid")
        command("docker", "restart", web)
        previous_port = port
        port = int(command("docker", "port", web, "8080/tcp").rsplit(":", 1)[1])
        self.results["restartHostPorts"] = [previous_port, port]
        self.ready(web, port)
        require(first != self.fingerprint(port), "Restart did not load renewed certificate")
        self.results["checks"].append("renewal-on-restart")
        self.ingress(valid)
        development, port = self.container("development", environment={"APP_ENVIRONMENT": "development"})
        self.ready(development, port, secure=False)
        self.check_content(port, secure=False)
        self.results["checks"].append("explicit-development-http")

    def ingress(self, identity):
        config = {
            "http": {"routers": {"web": {"rule": "Host(`localhost`)", "entryPoints": ["https"], "service": "web", "tls": {}}},
                     "services": {"web": {"loadBalancer": {"servers": [{"url": "https://web:8080"}], "serversTransport": "platform-https"}}},
                     "serversTransports": {"platform-https": {"serverName": "localhost", "insecureSkipVerify": False, "rootCAs": ["/fixtures/ca.pem"]}}},
            "tls": {"certificates": [{"certFile": "/run/secrets/https/tls.crt", "keyFile": "/run/secrets/https/tls.key"}]},
        }
        path = self.fixtures.root / "ingress.json"
        path.write_text(json.dumps(config))
        ingress, port = self.container("ingress", identity=identity, image=TRAEFIK,
                                       mounts=[(path, "/etc/traefik/dynamic.json"), (self.fixtures.ca_file, "/fixtures/ca.pem")],
                                       arguments=["--entrypoints.https.address=:8080", "--providers.file.filename=/etc/traefik/dynamic.json", "--log.level=WARN"])
        self.ready(ingress, port)
        self.check_content(port, secure=True)
        self.results["checks"].append("verified-traefik-https-on-both-hops")

    def cleanup(self):
        failures = []
        cleanup_failures = []
        for name, identifier in reversed(self.containers):
            try:
                result = subprocess.run(["docker", "logs", identifier], capture_output=True, text=True, timeout=15, check=True)
                logs = result.stdout + result.stderr
                (self.output / (name + ".log")).write_text(logs)
                if "synthetic-sensitive-value" in logs or "Enter PEM pass phrase" in logs:
                    failures.append(name + ": unsafe request logging or interactive key prompt")
            except Exception as error:
                failures.append(name + ": log retrieval failed (" + type(error).__name__ + ")")
            try:
                command("docker", "rm", "--force", "--volumes", identifier)
            except Exception as error:
                cleanup_failures.append(name + ": removal failed (" + type(error).__name__ + ")")
        if self.network:
            try:
                command("docker", "network", "rm", self.name)
            except Exception as error:
                cleanup_failures.append("Network removal failed (" + type(error).__name__ + ")")
        self.results["cleanupComplete"] = not cleanup_failures
        self.results["logPrivacyPassed"] = not failures
        require(not failures and not cleanup_failures, "; ".join(failures + cleanup_failures))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--output-directory", type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    output = args.output_directory or Path(tempfile.mkdtemp(prefix="trove-web-image-"))
    if args.output_directory:
        output.mkdir(parents=True, exist_ok=False)
    print("Evidence: " + str(output), flush=True)
    with tempfile.TemporaryDirectory(prefix="trove-web-certificates-") as root:
        verification = Verification(args.image, output, Certificates(Path(root)))
        try:
            verification.exercise()
            verification.results["passed"] = True
        finally:
            try:
                verification.cleanup()
            except BaseException:
                verification.results["passed"] = False
                raise
            finally:
                (output / "summary.json").write_text(json.dumps(verification.results, indent=2) + "\n")
    print("PASS: dashboard image transport, startup failures, routing, renewal and log privacy.", flush=True)


if __name__ == "__main__":
    main()
