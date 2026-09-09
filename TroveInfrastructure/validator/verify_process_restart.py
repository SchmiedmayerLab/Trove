"""Verify the two-study checkpoint across two real backend processes using disposable resources.

Requires Docker, a compiled native TroveServer, and verified Keycloak/validator assets.
Starts its own disposable PostgreSQL/Timescale, S3, Keycloak, validator and backend.
All study operations use authenticated REST; SQL is only for operator provisioning
and verification of the uniquely owned database. No existing services are modified.
"""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import argparse
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]
KEYCLOAK_SHA = "f3ce596dcf772ae145581ef338f9c3937ee37c74d7c1793e563c61519baaaafc"
PROFILE = "https://grovealliance.org/fhir/mobile/StructureDefinition/grove-mobile-heart-rate"
PDF = b"%PDF-1.4 Synthetic process-restart consent evidence"
POSTGRES_IMAGE = "timescale/timescaledb:latest-pg18@sha256:9508616d5b941ed931198504c5db3fb47e8f53f790732ea1e889591f1062057c"
STORAGE_IMAGE = "chrislusf/seaweedfs@sha256:f7cbc8bdbbf60a1aaba7d61784a3bdff3ec1e0657f6ad0b26d5b6ab2cd9d0dc6"

# The relay can reach only its fixed worker destination in this implementation.
# The worker itself has only the internal network, without Internet egress.
RELAY = r'''
import http.client,http.server,sys
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def forward(self):
        if self.path not in ('/health','/validate'):
            self.send_error(404); return
        size=int(self.headers.get('Content-Length','0'))
        if not 0 <= size <= 4194304:
            self.send_error(413); return
        self.connection.settimeout(10)
        body=self.rfile.read(size)
        connection=http.client.HTTPConnection(sys.argv[1],8080,timeout=130)
        try:
            connection.request(self.command,self.path,body=body,headers={'Content-Type':'application/fhir+json'})
            response=connection.getresponse(); data=response.read(2049)
            self.send_response(response.status); self.send_header('Content-Length',str(len(data)))
            self.end_headers(); self.wfile.write(data)
        finally: connection.close()
    do_GET=forward
    do_POST=forward
http.server.HTTPServer(('0.0.0.0',8080),Handler).serve_forever()
'''


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def request(url, method="GET", data=None, token=None, headers=None, expected=200):
    headers = dict(headers or {})
    if token:
        headers["Authorization"] = "Bearer " + token
    if isinstance(data, (dict, list)):
        data = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers, method=method), timeout=150) as response:
            status, body = response.status, response.read(10_000_001)
    except urllib.error.HTTPError as error:
        status, body = error.code, error.read(2048)
    require(status == expected, f"{method} {urllib.parse.urlsplit(url).path}: expected {expected}, received {status}")
    return body


class Checkpoint:
    def __init__(self, args):
        self.args = args
        self.evidence = Path(tempfile.mkdtemp(prefix="trove-process-restart-", dir="/private/tmp"))
        self.name = "trove_restart_" + uuid.uuid4().hex[:12]
        self.bucket = self.name.replace("_", "-")
        self.runtime_password = "synthetic-" + uuid.uuid4().hex
        self.processes, self.containers = [], []
        self.backends = []
        self.pg_container = self.name + "-postgres"
        self.storage_container = self.name + "-storage"
        self.monitor_stop = threading.Event()
        self.monitor = None
        self.memory = {"backendSampledMaxRSSBytes": 0, "validatorSampledMaxBytes": 0, "backendSamples": 0, "validatorSamples": 0}
        self.started = time.monotonic()
        self.network_created = False
        self.container_scripts = "/tmp/" + self.name
        self.env = {"PATH": os.environ["PATH"], "APP_ENVIRONMENT": "development", "LOG_LEVEL": "warning",
                    "DATABASE_HOST": "127.0.0.1", "DATABASE_PORT": str(args.pg_port), "DATABASE_NAME": self.name,
                    "DATABASE_USERNAME": "trove_test", "DATABASE_PASSWORD": "trove_test"}
        self.api = f"http://127.0.0.1:{args.server_port}/api/v0"
        self.kc_url = f"http://127.0.0.1:{args.keycloak_port}"
        self.summary = {"database": self.name, "bucket": self.bucket, "passed": False,
                        "startedAt": datetime.now(timezone.utc).isoformat(), "postgresImage": POSTGRES_IMAGE, "storageImage": STORAGE_IMAGE}

    def run(self, command, *, data=None, env=None, log="commands.log", timeout=180):
        with (self.evidence / log).open("ab") as output:
            result = subprocess.run(command, input=data, env=env, cwd=self.evidence,
                                    stdout=subprocess.PIPE, stderr=output, timeout=timeout, check=False)
            require(result.returncode == 0, f"Verification command failed; inspect {log}")
            return result.stdout

    def sql(self, statement, database=None):
        return self.run(["docker", "exec", "-i", "--env", "PGPASSWORD=trove_test", self.pg_container,
                         "psql", "-X", "-h", "127.0.0.1", "-U", "trove_test", "-d", database or self.name,
                         "-v", "ON_ERROR_STOP=1", "-Atq"], data=statement.encode()).decode().strip()

    def start(self, command, env, log):
        with (self.evidence / log).open("wb") as output:
            process = subprocess.Popen(command, env=env, cwd=self.evidence, stdout=output,
                                       stderr=subprocess.STDOUT, start_new_session=True)
        self.processes.append(process)
        return process

    @staticmethod
    def stop(process):
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=10)
        require(process.poll() is not None, "Owned process did not terminate")

    def ready(self, url, process=None):
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            require(process is None or process.poll() is None, "Owned service exited before readiness")
            try:
                with urllib.request.urlopen(url, timeout=2) as response:
                    if response.status == 200:
                        return
            except (OSError, urllib.error.URLError):
                pass
            time.sleep(1)
        raise RuntimeError("Owned service readiness timed out")

    def prepare(self):
        for port in (self.args.pg_port, self.args.s3_port, self.args.server_port, self.args.keycloak_port, self.args.management_port, self.args.validator_port):
            with socket.socket() as probe:
                probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                probe.bind(("127.0.0.1", port))
        binary = self.evidence / "TroveServer"
        shutil.copy2(self.args.binary, binary)
        self.summary["binarySHA256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
        require(hashlib.sha256(self.args.keycloak_archive.read_bytes()).hexdigest() == KEYCLOAK_SHA,
                "Keycloak archive does not match the reviewed checksum")
        manifest = self.args.assets / "manifest.json"
        require(manifest.read_bytes() == (ROOT / "TroveInfrastructure/validator/manifest.json").read_bytes(),
                "Validator assets differ from the reviewed manifest")
        self.identity = "sha256:" + hashlib.sha256(manifest.read_bytes()).hexdigest()
        self.summary["validatorIdentity"] = self.identity
        images = json.loads(self.run(["docker", "image", "inspect", self.args.image, POSTGRES_IMAGE, STORAGE_IMAGE]))
        self.validator_image = images[0]["Id"]
        self.summary["validatorImageID"] = self.validator_image
        self.prepare_stores()
        self.sql(f"CREATE DATABASE {self.name};", database="postgres")
        self.sql("CREATE EXTENSION IF NOT EXISTS timescaledb;")
        self.run([str(binary), "migrate", "--yes"], env=self.env, log="migrate.log")
        self.provision_runtime()
        self.prepare_keycloak()
        self.prepare_validator()
        self.env.update(S3_ENDPOINT=f"http://127.0.0.1:{self.args.s3_port}", S3_ACCESS_KEY="trove_test",
                        S3_SECRET_KEY="trove_test", S3_BUCKET=self.bucket, S3_REGION="us-east-1",
                        FHIR_VALIDATOR_URL=f"http://127.0.0.1:{self.args.validator_port}/validate", FHIR_VALIDATOR_IDENTITY=self.identity)
        self.monitor = threading.Thread(target=self.sample_memory, daemon=True)
        self.monitor.start()

    def provision_runtime(self):
        self.run(["docker", "exec", self.pg_container, "mkdir", self.container_scripts])
        for filename in ("grant-runtime.sh", "grant-runtime.sql"):
            self.run(["docker", "cp", str(ROOT / "TroveInfrastructure/database-operator" / filename),
                      self.pg_container + ":" + self.container_scripts + "/" + filename])
        command = ["docker", "exec", "-i"]
        for key, value in {"PGHOST": "127.0.0.1", "PGPORT": "5432", "PGDATABASE": self.name,
                           "PGUSER": "trove_test", "PGPASSWORD": "trove_test",
                           "DATABASE_USERNAME": self.name, "DATABASE_PASSWORD": self.runtime_password}.items():
            command += ["--env", f"{key}={value}"]
        self.run(command + [self.pg_container, "bash", self.container_scripts + "/grant-runtime.sh"], log="grants.log")
        self.env.update(DATABASE_USERNAME=self.name, DATABASE_PASSWORD=self.runtime_password)

    def postgres_arguments(self) -> tuple[list[str], list[str]]:
        return ["--memory", "2g", "--cpus", "2", "--tmpfs", "/pgdata:size=1g,mode=0700"], []

    def prepare_stores(self):
        runtime, configuration = self.postgres_arguments()
        self.run(["docker", "create", "--name", self.pg_container, "-p", f"127.0.0.1:{self.args.pg_port}:5432",
                  *runtime,
                  "--env", "PGDATA=/pgdata", "--env", "POSTGRES_USER=trove_test", "--env", "POSTGRES_PASSWORD=trove_test",
                  "--env", "POSTGRES_DB=postgres", "--env", "POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256", POSTGRES_IMAGE,
                  *configuration])
        self.containers.append(self.pg_container)
        self.run(["docker", "start", self.pg_container])
        for _ in range(90):
            try:
                if self.sql("SELECT 1;", database="postgres") == "1":
                    break
            except RuntimeError:
                time.sleep(1)
        else:
            raise RuntimeError("Disposable PostgreSQL did not become ready")
        storage = self.storage_container
        self.run(["docker", "create", "--name", storage, "-p", f"127.0.0.1:{self.args.s3_port}:8333",
                  "--memory", "2g", "--cpus", "2", "--tmpfs", "/data:size=1g", STORAGE_IMAGE,
                  "server", "-s3", "-dir=/data", "-master.volumeSizeLimitMB=100", "-volume.port=8081",
                  "-volume.max=32", "-master.telemetry=false"])
        self.containers.append(storage)
        self.run(["docker", "start", storage])
        self.ready(f"http://127.0.0.1:{self.args.s3_port}/")

    def sample_memory(self):
        units = {"B": 1, "KiB": 1024, "MiB": 1024**2, "GiB": 1024**3}
        while not self.monitor_stop.is_set():
            for process in tuple(self.backends):
                if process.poll() is None:
                    result = subprocess.run(["ps", "-o", "rss=", "-p", str(process.pid)], capture_output=True, timeout=5, check=False)
                    if result.returncode == 0 and result.stdout.strip().isdigit():
                        self.memory["backendSampledMaxRSSBytes"] = max(self.memory["backendSampledMaxRSSBytes"], int(result.stdout) * 1024)
                        self.memory["backendSamples"] += 1
            try:
                result = subprocess.run(["docker", "stats", "--no-stream", "--format", "{{.MemUsage}}", self.name + "-worker"],
                                        capture_output=True, timeout=10, check=False)
                value = result.stdout.decode().split("/")[0].strip()
                for unit in ("GiB", "MiB", "KiB", "B"):
                    if value.endswith(unit):
                        amount = int(float(value[:-len(unit)]) * units[unit])
                        self.memory["validatorSampledMaxBytes"] = max(self.memory["validatorSampledMaxBytes"], amount)
                        self.memory["validatorSamples"] += 1
                        break
            except (OSError, ValueError, subprocess.TimeoutExpired):
                pass
            self.monitor_stop.wait(2)

    def prepare_keycloak(self, *, participant_usernames=()):
        with tarfile.open(self.args.keycloak_archive) as archive:
            archive.extractall(self.evidence, filter="data")
        home = self.evidence / "keycloak-26.6.1"
        realm = json.loads((ROOT / "TroveInfrastructure/docker/keycloak/realm.json").read_bytes())
        existing = {user["username"] for user in realm["users"]}
        require(len(set(participant_usernames)) == len(participant_usernames)
                and not (existing | {"audit-reader@example.com"}).intersection(participant_usernames), "Duplicate synthetic participant")
        # Only this owned verification realm receives a dedicated reader. The
        # repository's ordinary administrator fixture remains without audit access.
        require("audit-reader@example.com" not in existing, "Duplicate synthetic audit reader")
        reader = copy.deepcopy(next(user for user in realm["users"] if user["username"] == "leland@example.com"))
        reader.pop("id", None)
        reader.update(username="audit-reader@example.com", email="audit-reader@example.com",
                      groups=["/Schmiedmayer Lab/admin", "/Schmiedmayer Lab/researcher", "/Schmiedmayer Lab/audit-reader"])
        realm["users"].append(reader)
        template = next(user for user in realm["users"] if user["username"] == "alice@example.com")
        for username in participant_usernames:
            user = copy.deepcopy(template)
            user.pop("id", None)
            user.update(username=username, email=username)
            realm["users"].append(user)
        self.password = next(c["value"] for u in realm["users"] if u["username"] == "alice@example.com"
                             for c in u["credentials"] if c["type"] == "password")
        scopes = realm.pop("clientScopes")
        for client in realm["clients"]:
            assigned = client.get("defaultClientScopes", [])
            expanded = [scope for scope in scopes if scope["name"] in assigned]
            client["defaultClientScopes"] = [scope for scope in assigned if scope not in {item["name"] for item in expanded}]
            client["protocolMappers"] = client.get("protocolMappers", []) + [mapper for scope in expanded for mapper in scope.get("protocolMappers", [])]
            if client["clientId"] == "trove-server":
                client["secret"] = "synthetic-process-restart-server-secret"
        directory = home / "data/import"
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "trove-realm.json").write_text(json.dumps(realm))
        kc_env = {"PATH": os.environ["PATH"], "JAVA_HOME": str(self.args.java_home),
                  "KC_BOOTSTRAP_ADMIN_USERNAME": "admin", "KC_BOOTSTRAP_ADMIN_PASSWORD": "synthetic-restart-admin"}
        process = self.start([str(home / "bin/kc.sh"), "start-dev", "--health-enabled=true", "--import-realm",
                              "--http-host=127.0.0.1", "--http-management-host=127.0.0.1",
                              f"--http-port={self.args.keycloak_port}", f"--http-management-port={self.args.management_port}",
                              "--hostname=" + self.kc_url], kc_env, "keycloak.log")
        self.ready(self.kc_url + "/realms/trove", process)
        self.env.update(KEYCLOAK_URL=self.kc_url, KEYCLOAK_REALM="trove", KEYCLOAK_ISSUER=self.kc_url + "/realms/trove",
                        KEYCLOAK_API_AUDIENCE="trove-api", KEYCLOAK_CLIENT_ID="trove-server",
                        KEYCLOAK_CLIENT_SECRET="synthetic-process-restart-server-secret",
                        KEYCLOAK_RESEARCHER_ROLE="trove-researcher", KEYCLOAK_PARTICIPANT_ROLE="trove-participant")

    def prepare_validator(self):
        self.run(["docker", "network", "create", "--internal", self.name])
        self.network_created = True
        worker, relay = self.name + "-worker", self.name + "-relay"
        limits = ["--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--pids-limit", "128",
                  "--memory", "4g", "--cpus", "2", "--tmpfs", "/tmp:size=2g,mode=1777,noexec,nosuid,nodev"]
        self.run(["docker", "create", "--name", worker, "--network", self.name, *limits, self.validator_image])
        self.containers.append(worker)
        self.run(["docker", "start", worker])
        self.run(["docker", "create", "--name", relay, "--network", "bridge", "-p", f"127.0.0.1:{self.args.validator_port}:8080",
                  "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--memory", "128m", "--pids-limit", "32",
                  "--entrypoint", "python3", self.validator_image, "-c", RELAY, worker])
        self.containers.append(relay)
        self.run(["docker", "network", "connect", self.name, relay])
        self.run(["docker", "start", relay])
        self.ready(f"http://127.0.0.1:{self.args.validator_port}/health")

    def backend(self, number):
        process = self.start([str(self.evidence / "TroveServer"), "serve", "--hostname", "127.0.0.1",
                              "--port", str(self.args.server_port)], self.env, f"server-{number}.log")
        self.backends.append(process)
        self.ready(self.api + "/health", process)
        return process

    def replace_backend(self, previous):
        self.stop(previous)
        return self.backend(2)

    def token(self, username):
        data = urllib.parse.urlencode({"grant_type": "password", "client_id": "trove-dev-cli",
                                       "username": username, "password": self.password}).encode()
        return json.loads(request(self.kc_url + "/realms/trove/protocol/openid-connect/token", "POST", data,
                                  headers={"Content-Type": "application/x-www-form-urlencoded"}))["access_token"]

    def api_json(self, path, token, method="GET", data=None, expected=200):
        return json.loads(request(self.api + path, method, data, token, expected=expected))

    def consent(self, enrollment, token):
        path = f"/participant/enrollments/{enrollment}/consents"
        reviewed = self.api_json(f"/participant/enrollments/{enrollment}/consent-presentation?locale=en-US", token)
        require(hashlib.sha256(reviewed["markdown"].encode()).hexdigest() == reviewed["presentation"]["digest"], "Presentation digest mismatch")
        boundary = "restart-" + uuid.uuid4().hex
        parts = []
        for name, content, mime in (("presentation", json.dumps(reviewed["presentation"]).encode(), "application/json"),
                                    ("reviewedRevision", b"1", "application/json"),
                                    ("consentData", b'{"toggles":{"agree":true}}', "application/json"),
                                    ("consentPDF", PDF, "application/pdf")):
            parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\nContent-Type: {mime}\r\n\r\n'.encode() + content + b"\r\n")
        body = b"".join(parts) + f"--{boundary}--\r\n".encode()
        headers = {"Content-Type": "multipart/form-data; boundary=" + boundary,
                   "Idempotency-Key": str(uuid.uuid4()), "If-Match": reviewed["enrollmentETag"]}
        receipt = json.loads(request(self.api + path, "POST", body, token, headers, expected=201))
        require(receipt["presentation"] == reviewed["presentation"], "Receipt does not match reviewed presentation")
        return receipt

    def prepare_studies(self):
        """Create the same synthetic participant and two consented studies through REST."""
        researcher, participant = self.token("leland@example.com"), self.token("alice@example.com")
        self.api_json("/participant/profile", participant, "POST", {
            "firstName": "Alice", "lastName": "Participant", "gender": "preferNotToState", "dateOfBirth": "1990-01-01",
            "region": "US", "language": "en-US", "phoneNumber": "+16505550123"}, expected=201)
        group = self.api_json("/groups", researcher)[0]["id"]
        studies, enrollments, consents = [], [], []
        for label in ("A", "B"):
            study = self.api_json(f"/groups/{group}/studies", researcher, "POST", {"title": f"Restart Study {label}", "icon": "heart"}, 201)["id"]
            self.api_json(f"/studies/{study}", researcher, "PATCH", {
                "consent": {"en-US": {"title": "Synthetic Consent", "content": '<toggle id="agree" expected-value="true">I agree.</toggle>'}},
                "collectionRequirements": [{"profile": PROFILE, "sourceKind": "participant-app"}]})
            self.api_json(f"/studies/{study}/publish", researcher, "POST", expected=201)
            enrollment = self.api_json(f"/participant/studies/{study}/enrollments", participant, "POST", {}, 201)["id"]
            studies.append(study)
            enrollments.append(enrollment)
            consents.append(self.consent(enrollment, participant))
        return researcher, participant, studies, enrollments, consents

    def exercise(self):
        first = self.backend(1)
        researcher, participant, studies, enrollments, consents = self.prepare_studies()
        source = self.api_json("/participant/sources", participant, "POST", {"registrationID": str(uuid.uuid4())})
        event = self.run([sys.executable, str(ROOT / "TroveInfrastructure/validator/rekey_fixture.py"), "--assets", str(self.args.assets),
                          "--fixture", str(ROOT / "TroveServer/Tests/TroveServerTests/Resources/ImmutablePointEvent.json"),
                          "--event-system", source["eventIdentifierSystem"], "--producer-instance", source["producerInstance"],
                          "--participant-system", source["participantIdentifier"]["system"], "--participant-value", source["participantIdentifier"]["value"],
                          "--effective-at", datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")])
        (self.evidence / "event.json").write_bytes(event)
        path = f'/participant/sources/{source["id"]}/events'
        outputs = [entry["fullUrl"] for entry in json.loads(event)["entry"] if entry["resource"]["resourceType"] == "Observation"]
        targets = [{"consentId": consent["id"], "outputFullUrls": outputs} for consent in consents]
        submission = {"eventBase64": base64.b64encode(event).decode(), "targets": targets[:1]}
        receipt = request(self.api + path, "POST", submission, participant)
        accepted = json.loads(receipt)
        require(accepted["sourceId"] == source["id"], "Receipt does not identify the accepted source")
        producer_identifier = json.loads(event)["identifier"]
        require(accepted["producerEventIdentifier"] == {
            key: producer_identifier[key] for key in ("system", "value")
        }, "Receipt does not identify the accepted producer event")
        require(accepted["payloadSHA256"] == hashlib.sha256(event).hexdigest(),
                "Receipt does not identify the accepted event bytes")
        canonical_targets = sorted(
            ({"consentId": item["consentId"].lower(), "outputFullUrls": sorted(item["outputFullUrls"])} for item in submission["targets"]),
            key=lambda item: item["consentId"],
        )
        intent_digest = hashlib.sha256(json.dumps(canonical_targets, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        require(accepted["targetIntentSHA256"] == intent_digest, "Receipt does not identify the original target intent")
        require(request(self.api + path, "POST", submission, participant) == receipt, "Initial retry changed receipt bytes")
        attribution_path = path + f'/{accepted["eventId"]}/attributions'
        attribution = {"commandId": str(uuid.uuid4()), "targets": targets[1:]}
        attribution_receipt = self.api_json(attribution_path, participant, "POST", attribution)
        require(attribution_receipt["authorizedOutputCount"] == 1, "Late attribution did not grant exactly the second study output")
        require(self.api_json(attribution_path, participant, "POST", attribution) == attribution_receipt,
                "Attribution retry changed its original receipt")
        self.api_json(attribution_path, participant, "POST", {**attribution, "targets": targets[:1]}, 409)
        self.check_state(studies, event, withdrawn=False)
        request(self.api + path, "POST", {**submission, "eventBase64": base64.b64encode(event + b" ").decode()}, participant, expected=409)
        request(self.api + path, "POST", {**submission, "targets": targets}, participant, expected=409)
        self.api_json(f"/participant/enrollments/{enrollments[0]}/withdraw", participant, "POST")
        self.check_state(studies, event, withdrawn=True)
        lookup_path = f'/participant/sources/{source["id"]}/event-receipts/lookup'
        lookup = {"producerEventIdentifier": accepted["producerEventIdentifier"],
                  "payloadSHA256": accepted["payloadSHA256"], "targets": submission["targets"]}
        require(self.api_json(lookup_path, participant, "POST", lookup) == accepted,
                "Receipt recovery after withdrawal changed the immutable acknowledgement")
        # A second stream is already revoked in the snapshot. The primary stream
        # remains active so the original retry/revocation checks still run after restore.
        retired = self.api_json("/participant/sources", participant, "POST", {"registrationID": str(uuid.uuid4())})
        retired = self.api_json(f'/participant/sources/{retired["id"]}/revoke', participant, "POST")
        self.check_revoked_source(retired, participant, submission)
        prior_audit = self.check_study_audit(studies, researcher, participant)
        second = self.replace_backend(first)
        require(first.pid != second.pid and first.poll() is not None, "Backend was not replaced by a new OS process")
        participant = self.token("alice@example.com")
        self.check_revoked_source(retired, participant, submission)
        require(request(self.api + path, "POST", submission, participant) == receipt, "Restart retry changed receipt bytes")
        require(self.api_json(attribution_path, participant, "POST", attribution) == attribution_receipt,
                "Late attribution receipt did not survive backend process replacement")
        self.api_json(f'/participant/sources/{source["id"]}/revoke', participant, "POST")
        require(self.api_json(lookup_path, participant, "POST", lookup) == accepted,
                "Receipt recovery after process restart and source revocation failed")
        request(self.api + path, "POST", submission, participant, expected=409)
        require(self.api_json(attribution_path, participant, "POST", attribution) == attribution_receipt,
                "Source revocation lost the original attribution receipt")
        self.api_json(attribution_path, participant, "POST", {**attribution, "commandId": str(uuid.uuid4())}, 409)
        self.api_json(lookup_path, participant, "POST", {**lookup, "payloadSHA256": "0" * 64}, 409)
        self.api_json(lookup_path, researcher, "POST", lookup, 403)
        require(self.sql("SELECT count(*) FROM audit_events WHERE action='clinical.event.receipt.disclosure' AND outcome='disclosure_intent';") == "2",
                "Receipt disclosures lack committed intent or denied lookups disclosed data")
        self.check_state(studies, event, withdrawn=True)
        for enrollment, consent in zip(enrollments, consents):
            actual = request(self.api + f'/participant/enrollments/{enrollment}/consents/{consent["id"]}/pdf', token=participant)
            require(actual == PDF, "Retained consent PDF changed across process restart")
        restored_audit = self.check_study_audit(studies, researcher, participant)
        require(prior_audit.issubset(restored_audit), "Scoped audit history did not survive backend replacement")
        self.summary["studyAuditReader"] = {"explicitCapabilityRequired": True, "administratorDenied": True,
            "participantDenied": True, "foreignCursorDenied": True, "retainedAcrossRestart": len(prior_audit),
            "scopedDisclosureIntents": 2}
        self.summary["retainedSourceRevocation"] = {"revokedBeforeReplacement": True,
            "registrationRetryRemainsRevoked": True, "revocationRetryRemainsUnchanged": True,
            "admissionDeniedBeforeAndAfter": True, "revocationAudits": 1}
        require(self.memory["backendSamples"] > 0 and self.memory["validatorSamples"] > 0, "Missing observed memory samples")
        self.summary.update(passed=True, backendPIDs=[first.pid, second.pid], eventSHA256=hashlib.sha256(event).hexdigest(),
                            receipt=json.loads(receipt), events=1, facts=1, grants=2, effectiveGrantsAfterWithdrawal=[0, 1],
                            nodeCount=len(json.loads(event)["entry"]), receiverAuditEvents=4,
                            lateAttributionReceipt=attribution_receipt,
                            receiptRecoveryAfterRevocation=True, receiptDisclosureIntents=2,
                            retainedConsentPDFs=2, runtimeRole=self.name)

    def check_revoked_source(self, source: dict[str, object], participant: str, submission: dict[str, object]) -> None:
        identifier, registration, revoked_at = source.get("id"), source.get("registrationID"), source.get("revokedAt")
        if not isinstance(identifier, str) or not isinstance(registration, str) or not isinstance(revoked_at, str):
            raise RuntimeError("Revoked source fixture lacks its identity or revocation time")
        identifier, registration = uuid.UUID(identifier), uuid.UUID(registration)
        require(datetime.fromisoformat(revoked_at.replace("Z", "+00:00")).tzinfo is not None,
                "Revoked source fixture lacks a timezone")
        path = f"/participant/sources/{identifier}"
        require(self.api_json(path, participant) == source, "Restored source identity or revocation changed")
        require(self.api_json("/participant/sources", participant, "POST", {"registrationID": str(registration)}) == source,
                "Registration retry reopened or replaced a revoked source")
        require(self.api_json(path + "/revoke", participant, "POST") == source,
                "Revocation retry changed its retained timestamp or identity")
        denied = self.api_json(path + "/events", participant, "POST", submission, 409)
        require(denied.get("detail") == "Source binding is not active",
                "Retained source was not rejected at the revocation boundary")
        require(self.sql(f"SELECT count(*) FROM audit_events WHERE action='source.revoked' "
                         f"AND source_binding_id='{identifier}' AND outcome='succeeded';") == "1",
                "Revocation audit was missing or duplicated by recovery/retries")

    def check_study_audit(self, studies, researcher, participant):
        study, other = (str(uuid.UUID(value)) for value in studies)
        path = f"/studies/{study}/audit-events?limit=100"
        for token in (researcher, participant):
            request(self.api + path, token=token, expected=403)
        expected = self.sql(f"""SELECT a.id FROM audit_events a JOIN studies s ON s.id=a.study_id AND s.group_id=a.group_id
            WHERE a.scope_kind='study' AND a.study_id='{study}' ORDER BY a.occurred_at DESC, a.id DESC LIMIT 100;""").splitlines()
        require(bool(expected) and len(expected) < 100, "Unexpected synthetic audit fixture size")
        reader = self.token("audit-reader@example.com")
        page = self.api_json(path, reader)
        require(str(uuid.UUID(page["studyId"])) == study and page.get("nextBefore") is None,
                "Audit page has the wrong study or unexpected truncation")
        identifiers = [str(uuid.UUID(record["id"])) for record in page["records"]]
        require(identifiers == expected, "Study audit page omitted records or included another scope")
        foreign = str(uuid.UUID(self.sql(f"SELECT id FROM audit_events WHERE study_id='{other}' ORDER BY id LIMIT 1;")))
        request(self.api + path + "&before=" + foreign, token=reader, expected=400)
        require(self.sql("SELECT count(*) FROM audit_events WHERE action='study.audit.disclosure';")
                == str(sum(record["action"] == "study.audit.disclosure" for record in page["records"]) + 1),
                "Denied reads produced audit grants or successful page lacked a committed intent")
        return set(identifiers)

    def check_state(self, studies, event, withdrawn):
        counts = self.sql("SELECT (SELECT count(*) FROM clinical_events), (SELECT count(*) FROM clinical_point_facts), (SELECT count(*) FROM study_data_grants);")
        require(counts == "1|1|2", "Unexpected retained event/fact/grant counts")
        require(self.sql("SELECT count(*) FROM clinical_event_nodes;") == str(len(json.loads(event)["entry"])),
                "Retained node index is incomplete or duplicated")
        require(self.sql("SELECT count(*) FROM audit_events WHERE action='clinical.event.accepted';") == "1",
                "Event acceptance audit was missing or duplicated")
        require(self.sql("SELECT count(*) FROM audit_events WHERE action='study.data.granted';") == "2",
                "Independent grant audits were missing or duplicated")
        require(self.sql("SELECT count(*) FROM clinical_attribution_commands;") == "1",
                "Late attribution command was lost or duplicated")
        require(self.sql("SELECT count(*) FROM audit_events WHERE action='clinical.event.attributed';") == "1",
                "Late attribution command audit was missing or duplicated")
        require(self.sql("SELECT encode(raw_bytes,'hex') FROM clinical_events;") == event.hex(), "Retained event bytes changed")
        for study, count in zip(studies, (0 if withdrawn else 1, 1)):
            require(str(uuid.UUID(study)) == study.lower(), "Invalid study identity")
            actual = self.sql(f"""SELECT count(DISTINCT g.node_id) FROM study_data_grants g
                JOIN enrollments e ON e.id=g.enrollment_id AND e.study_id=g.study_id
                JOIN enrollment_consents c ON c.id=g.consent_id AND c.enrollment_id=e.id AND c.revision=g.revision
                JOIN published_studies p ON p.id=g.publication_id AND p.study_id=g.study_id AND p.revision=g.revision
                JOIN clinical_event_nodes n ON n.id=g.node_id
                JOIN source_bindings s ON s.id=n.source_id AND s.participant_id=e.participant_id
                WHERE g.study_id='{study}' AND e.withdrawn_at IS NULL;""")
            require(actual == str(count), "Effective study grants do not respect withdrawal isolation")

    def cleanup(self):
        self.monitor_stop.set()
        if self.monitor is not None:
            self.monitor.join(timeout=15)
        errors = []
        def attempt(operation):
            try:
                operation()
            except Exception as error:
                errors.append(type(error).__name__)
        for process in reversed(self.processes):
            attempt(lambda process=process: self.stop(process))
        for container in reversed(self.containers):
            attempt(lambda container=container: (self.evidence / (container + ".log")).write_bytes(self.run(["docker", "logs", container])))
            attempt(lambda container=container: self.run(["docker", "rm", "--force", "--volumes", container]))
        if self.network_created:
            attempt(lambda: self.run(["docker", "network", "rm", self.name]))
        # Database, runtime role, script copies and bucket existed only inside these owned
        # disposable containers/tmpfs. Removing the containers removes those records too.
        self.summary["cleanupComplete"] = not errors
        self.summary["passed"] = self.summary.get("passed", False) and not errors
        self.summary["elapsedSeconds"] = round(time.monotonic() - self.started, 3)
        self.summary["memoryObservation"] = {**self.memory, "method": "sampled ps RSS and docker stats; not exact peak or benchmark"}
        (self.evidence / "summary.json").write_text(json.dumps(self.summary, indent=2) + "\n")
        require(not errors, "Owned resource cleanup incomplete; inspect evidence")


def add_stack_arguments(parser):
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--keycloak-archive", type=Path, required=True)
    parser.add_argument("--java-home", type=Path, required=True)
    parser.add_argument("--image", default="trove-fhir-validator:local-final")
    for name, port in (("pg", 58032), ("s3", 58033), ("server", 58080), ("keycloak", 58180), ("management", 59000), ("validator", 58081)):
        parser.add_argument("--" + name + "-port", type=int, default=port)


def run_verification(checkpoint, exercise, *, timeout_seconds=1800):
    require(type(timeout_seconds) is int and 1 <= timeout_seconds <= 3600, "Invalid verification deadline")
    def timed_out(*_):
        raise TimeoutError(f"Process checkpoint exceeded {timeout_seconds} seconds")
    signal.signal(signal.SIGALRM, timed_out)
    def interrupted(*_):
        raise InterruptedError("Process checkpoint interrupted")
    signal.signal(signal.SIGTERM, interrupted)
    signal.alarm(timeout_seconds)
    print("Evidence: " + str(checkpoint.evidence), flush=True)
    try:
        checkpoint.prepare()
        exercise()
    except BaseException:
        checkpoint.summary["passed"] = False
        raise
    finally:
        signal.alarm(0)
        checkpoint.cleanup()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    add_stack_arguments(parser)
    args = parser.parse_args()
    os.umask(0o077)
    checkpoint = Checkpoint(args)
    run_verification(checkpoint, checkpoint.exercise)
    print("PASS: real backend process restart retained one event, two study grants, isolated withdrawal, receipt recovery after revocation and both consent PDFs.", flush=True)


if __name__ == "__main__":
    main()
