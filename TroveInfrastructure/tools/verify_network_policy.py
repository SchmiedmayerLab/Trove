"""Exercise rendered production NetworkPolicies in an owned, disposable KIND cluster.

Synthetic TCP listeners prove pod-selector/port isolation through pod and Service
addresses, not application TLS, external routing, DNS policy, or the production CNI.
"""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass
import hashlib
import ipaddress
import json
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import uuid

import yaml

ROOT = Path(__file__).resolve().parents[1]
NODE_IMAGE = "kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0"
LISTENER = """
import selectors, socket
selector = selectors.DefaultSelector()
for port in (5432, 8000, 8080, 8443, 9187):
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('0.0.0.0', port))
    server.listen()
    selector.register(server, selectors.EVENT_READ)
while True:
    for key, _ in selector.select():
        client, _ = key.fileobj.accept()
        with client:
            client.settimeout(2)
            try:
                client.sendall(b'trove-network-probe')
            except (ConnectionError, TimeoutError):
                pass  # TCP readiness probes may close before reading.
"""
CLIENT = """
import json, socket, sys
try:
    with socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=2) as client:
        received = b''
        while len(received) < len(b'trove-network-probe'):
            data = client.recv(64)
            if not data:
                raise RuntimeError('Listener closed without its complete marker')
            received += data
        if received != b'trove-network-probe':
            raise RuntimeError('Unexpected listener response')
    print(json.dumps(True))
except TimeoutError:
    print(json.dumps(False))
"""


@dataclass(frozen=True)
class Role:
    name: str
    labels: dict[str, str]
    namespace: str = "trove"
    worker: bool = True


@dataclass(frozen=True)
class Case:
    source: str
    target: str
    port: int
    allowed: bool


ROLES = (
    Role("gateway", {"app.kubernetes.io/name": "traefik"}, worker=False),
    Role("api", {"app": "trove-server"}),
    Role("web", {"app": "trove-web"}),
    Role("schema", {"app": "trove-database-operator"}),
    Role("clinical-db", {"cnpg.io/cluster": "trove-db"}, worker=False),
    Role("identity", {"app": "keycloak"}),
    Role("identity-db", {"cnpg.io/cluster": "keycloak-db"}, worker=False),
    Role("importer", {"app": "keycloak-config-cli"}),
    Role("untrusted", {"app": "untrusted"}),
    Role("outside-gateway", {"app.kubernetes.io/name": "traefik"}, "policy-outsider", False),
    Role("db-operator", {"app": "cnpg-operator"}, "cnpg-system"),
)
CASES = (
    Case("gateway", "api", 8080, True), Case("gateway", "web", 8080, True),
    Case("gateway", "identity", 8443, True), Case("api", "clinical-db", 5432, True),
    Case("schema", "clinical-db", 5432, True), Case("identity", "identity-db", 5432, True),
    Case("db-operator", "clinical-db", 8000, True), Case("db-operator", "identity-db", 9187, True),
    Case("gateway", "identity", 8080, False), Case("gateway", "clinical-db", 5432, False),
    Case("web", "clinical-db", 5432, False), Case("web", "identity-db", 5432, False),
    Case("web", "api", 8080, False), Case("api", "identity-db", 5432, False),
    Case("api", "identity", 8443, False), Case("importer", "identity", 8443, False),
    Case("identity", "clinical-db", 5432, False), Case("schema", "api", 8080, False),
    Case("clinical-db", "api", 8080, False), Case("untrusted", "api", 8080, False),
    Case("untrusted", "clinical-db", 5432, False), Case("untrusted", "clinical-db", 8000, False),
    Case("outside-gateway", "api", 8080, False), Case("outside-gateway", "clinical-db", 5432, False),
)


def run(command: list[str], *, content: str | None = None, timeout: int = 120) -> str:
    return subprocess.run(command, input=content, text=True, capture_output=True, check=True, timeout=timeout).stdout


def rendered_policies() -> list[dict]:
    documents = yaml.safe_load_all(run(["kubectl", "kustomize", str(ROOT / "infrastructure/prod")]))
    policies = [document for document in documents if document["kind"] == "NetworkPolicy"]
    names = [policy["metadata"]["name"] for policy in policies]
    if len(names) != len(set(names)) or not {"default-deny-ingress", "default-deny-egress"}.issubset(names):
        raise ValueError("Production policy set is missing default denies or has duplicate names")
    if any(policy["metadata"].get("namespace") != "trove" for policy in policies):
        raise ValueError("Unexpected production policy namespace")
    return policies


def exercise(kind: str, image: str) -> None:
    policies = rendered_policies()
    evidence = Path(tempfile.mkdtemp(prefix="trove-network-policy-"))
    name = "trove-policy-" + uuid.uuid4().hex[:12]
    kubeconfig = evidence / "kubeconfig"
    checks = [(case, service) for case in CASES for service in (False, True)]
    summary = {"passed": False, "cluster": name, "nodeImage": NODE_IMAGE,
               "cases": [{**asdict(case), "path": "service" if service else "pod"} for case, service in checks]}
    print(f"Evidence: {evidence}", flush=True)
    # Resolve a local probe image before creating resources. It must contain python3.
    summary["probeImageID"] = run(["docker", "image", "inspect", "--format", "{{.Id}}", image]).strip()
    config = {"kind": "Cluster", "apiVersion": "kind.x-k8s.io/v1alpha4", "nodes": [
        {"role": "control-plane", "image": NODE_IMAGE}, {"role": "worker", "image": NODE_IMAGE}]}
    config_path = evidence / "kind.json"
    config_path.write_text(json.dumps(config))
    policy_bytes = json.dumps({"apiVersion": "v1", "kind": "List", "items": policies}, sort_keys=True)
    (evidence / "policies.json").write_text(policy_bytes)
    summary["policySHA256"] = hashlib.sha256(policy_bytes.encode()).hexdigest()

    def kubectl(*arguments: str, content: str | None = None, timeout: int = 120) -> str:
        return run(["kubectl", "--kubeconfig", str(kubeconfig), "--context", "kind-" + name,
                    "--request-timeout=30s", *arguments], content=content, timeout=timeout)

    roles = {role.name: role for role in ROLES}
    try:
        run([kind, "create", "cluster", "--name", name, "--config", str(config_path),
             "--kubeconfig", str(kubeconfig), "--wait", "120s"], timeout=240)
        run([kind, "load", "docker-image", image, "--name", name], timeout=240)
        for namespace in sorted({role.namespace for role in ROLES}):
            kubectl("create", "namespace", namespace)
        pods = [{"apiVersion": "v1", "kind": "Pod", "metadata": {
            "name": role.name, "namespace": role.namespace, "labels": role.labels}, "spec": {
            "nodeName": name + ("-worker" if role.worker else "-control-plane"),
            "automountServiceAccountToken": False, "restartPolicy": "Never",
            "securityContext": {"runAsUser": 10001, "runAsGroup": 10001, "runAsNonRoot": True},
            "containers": [{"name": "probe", "image": image, "imagePullPolicy": "Never",
                "command": ["python3", "-c", LISTENER],
                "securityContext": {"readOnlyRootFilesystem": True, "allowPrivilegeEscalation": False,
                                    "capabilities": {"drop": ["ALL"]}},
                "resources": {"limits": {"memory": "128Mi", "cpu": "250m"}},
                "readinessProbe": {"tcpSocket": {"port": 8080}, "periodSeconds": 1}}]}}
            for role in ROLES]
        kubectl("apply", "-f", "-", content=json.dumps({"apiVersion": "v1", "kind": "List", "items": pods}))
        services = [{"apiVersion": "v1", "kind": "Service", "metadata": {
            "name": role.name, "namespace": role.namespace}, "spec": {"selector": role.labels,
            "ports": [{"name": f"tcp-{port}", "port": 80 if role.name == "web" and port == 8080 else port,
                       "targetPort": port} for port in (5432, 8000, 8080, 8443, 9187)]}} for role in ROLES]
        kubectl("apply", "-f", "-", content=json.dumps({"apiVersion": "v1", "kind": "List", "items": services}))
        for namespace in sorted({role.namespace for role in ROLES}):
            kubectl("wait", "--for=condition=Ready", "pods", "--all", "-n", namespace, "--timeout=90s")
        addresses = {role.name: str(ipaddress.IPv4Address(kubectl(
            "get", "pod", role.name, "-n", role.namespace, "-o", "jsonpath={.status.podIP}").strip())) for role in ROLES}
        service_addresses = {role.name: str(ipaddress.IPv4Address(kubectl(
            "get", "service", role.name, "-n", role.namespace, "-o", "jsonpath={.spec.clusterIP}").strip())) for role in ROLES}

        def probe(check: tuple[Case, bool]) -> bool:
            case, service = check
            address = (service_addresses if service else addresses)[case.target]
            port = 80 if service and case.target == "web" and case.port == 8080 else case.port
            value = json.loads(kubectl("exec", "-n", roles[case.source].namespace, case.source, "--",
                                       "python3", "-c", CLIENT, address, str(port), timeout=15))
            if type(value) is not bool:
                raise ValueError("Probe returned an invalid outcome")
            return value

        with ThreadPoolExecutor(max_workers=4) as pool:
            if not all(pool.map(probe, checks)):
                raise RuntimeError("A listener is unreachable before policy installation")
            summary["baselineReachable"] = True
            kubectl("apply", "-f", "-", content=policy_bytes)
            deadline = time.monotonic() + 120
            matches = 0
            while time.monotonic() < deadline:
                outcomes = list(pool.map(probe, checks))
                summary["outcomes"] = outcomes
                matches = matches + 1 if outcomes == [case.allowed for case, _ in checks] else 0
                if matches == 2:
                    break
            if matches != 2:
                raise RuntimeError("Production policy matrix did not pass twice within the bounded convergence window")
        summary.update(passed=True, baselineReachable=True, consecutivePassingMatrices=matches)
    finally:
        try:
            run([kind, "delete", "cluster", "--name", name, "--kubeconfig", str(kubeconfig)], timeout=120)
            kubeconfig.unlink(missing_ok=True)
            summary["cleanupComplete"] = True
        except BaseException:
            summary.update(passed=False, cleanupComplete=False)
            raise
        finally:
            (evidence / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("PASS: rendered pod/port policy matrix and owned-cluster cleanup; local CNI only.", flush=True)


def interrupted(_signal: int, _frame: object) -> None:
    raise InterruptedError("Network-policy verification interrupted")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", default="kind")
    parser.add_argument("--probe-image", required=True, help="Local image containing python3; no application secrets are used")
    arguments = parser.parse_args()
    signal.signal(signal.SIGTERM, interrupted)
    exercise(arguments.kind, arguments.probe_image)
