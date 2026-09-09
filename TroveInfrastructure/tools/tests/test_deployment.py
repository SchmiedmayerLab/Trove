# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

"""Check the rendered deployment contract, not just individual YAML fragments."""

import json
from pathlib import Path
import subprocess
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
OWNER = "trove-postgres-credentials"
RUNTIME = "trove-postgres-runtime-credentials"


def named(documents, kind, name):
    matches = [item for item in documents if item["kind"] == kind and item["metadata"]["name"] == name]
    if len(matches) != 1:
        raise AssertionError(f"Expected exactly one {kind}/{name}, found {len(matches)}")
    return matches[0]


def secrets(container):
    return {entry["valueFrom"]["secretKeyRef"]["name"] for entry in container.get("env", [])
            if "secretKeyRef" in entry.get("valueFrom", {})}


class DeploymentContractTests(unittest.TestCase):
    def test_infrastructure_uses_server_side_diff_without_ignoring_desired_fields(self):
        application = yaml.safe_load((ROOT / "argocd-apps/base/infrastructure.yaml").read_text())
        self.assertEqual(application["metadata"]["annotations"]["argocd.argoproj.io/compare-options"],
                         "ServerSideDiff=true")
        self.assertNotIn("ignoreDifferences", application["spec"])

    def test_development_ingress_ports_match_the_network_policy(self):
        values = yaml.safe_load((ROOT / "argocd-apps/dev/traefik-values.yaml").read_text())
        ingress = named(self.rendered["infrastructure", "dev"], "NetworkPolicy", "allow-external-to-traefik")
        ports = {port["port"] for rule in ingress["spec"]["ingress"] for port in rule["ports"]}
        self.assertEqual(ports, {values["ports"]["web"]["port"], values["ports"]["websecure"]["port"]})
        self.assertEqual(values["ports"]["web"]["nodePort"], 30080)
        self.assertEqual(values["ports"]["websecure"]["nodePort"], 30443)

    def test_audit_reader_capability_is_available_but_never_assigned_by_default(self):
        for path in (ROOT / "docker/keycloak/realm.json", ROOT / "infrastructure/dev/realm/00-realm.json"):
            with self.subTest(path=path):
                realm = json.loads(path.read_text())
                group = next(item for item in realm["groups"] if item["name"] == "Schmiedmayer Lab")
                readers = [item for item in group["subGroups"] if item["name"] == "audit-reader"]
                self.assertEqual(readers, [{"name": "audit-reader", "subGroups": []}])
                for user in realm.get("users", []):
                    self.assertFalse(any(value.endswith("/audit-reader") for value in user.get("groups", [])))
                self.assertFalse(any(value.endswith("/audit-reader") for value in realm.get("defaultGroups", [])))

    def test_local_cluster_uses_the_verified_extension_compatible_node(self):
        configuration = yaml.safe_load((ROOT / "tools/kind-config.yaml").read_text())
        self.assertEqual(configuration["nodes"][0]["image"],
                         "kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0")
        self.assertFalse(configuration.get("networking", {}).get("disableDefaultCNI", False))
        self.assertEqual(configuration["networking"]["serviceSubnet"], "10.96.0.0/12")

    def test_development_api_egress_replaces_production_addresses_without_opening_other_destinations(self):
        for name in ("allow-cnpg-to-k8s-api", "allow-traefik-egress"):
            with self.subTest(policy=name):
                development = named(self.rendered["infrastructure", "dev"], "NetworkPolicy", name)
                production = named(self.rendered["infrastructure", "prod"], "NetworkPolicy", name)
                cidrs = lambda policy: {peer["ipBlock"]["cidr"] for rule in policy["spec"]["egress"]
                                        for peer in rule["to"] if "ipBlock" in peer}
                self.assertEqual(cidrs(development), {"10.96.0.1/32", "192.0.2.1/32"})
                self.assertEqual(cidrs(production), {"10.8.0.1/32", "172.16.0.0/28"})
                api_rules = [rule for rule in development["spec"]["egress"]
                             if rule["ports"] == [{"protocol": "TCP", "port": 6443}]]
                self.assertEqual(api_rules, [{"to": [{"ipBlock": {"cidr": "192.0.2.1/32"}}],
                                             "ports": [{"protocol": "TCP", "port": 6443}]}])

    def test_local_and_ci_object_stores_bound_collection_slots_and_disable_telemetry(self):
        storage = named(self.rendered["infrastructure", "dev"], "StatefulSet", "seaweedfs")
        arguments = storage["spec"]["template"]["spec"]["containers"][0]["args"]
        compose = yaml.safe_load((ROOT / "docker/docker-compose.yml").read_text())
        for flag in ("-volume.max=32", "-master.telemetry=false"):
            self.assertIn(flag, arguments)
            self.assertIn(flag, compose["services"]["seaweedfs"]["command"].split())
            self.assertIn(flag, (ROOT / "validator/verify_process_restart.py").read_text())
            self.assertIn(flag, (ROOT.parent / ".github/workflows/swift-package.yml").read_text())

    @classmethod
    def setUpClass(cls):
        cls.rendered = {}
        for layer in ("apps", "infrastructure"):
            for environment in ("dev", "prod"):
                result = subprocess.run(
                    ["kubectl", "kustomize", str(ROOT / layer / environment)],
                    capture_output=True, text=True, check=True, timeout=30,
                )
                cls.rendered[layer, environment] = list(yaml.safe_load_all(result.stdout))

    def test_serving_never_receives_operator_credentials_or_initializes_schema(self):
        for environment in ("dev", "prod"):
            with self.subTest(environment=environment):
                deployment = named(self.rendered["apps", environment], "Deployment", "trove-server")
                pod = deployment["spec"]["template"]["spec"]
                self.assertNotIn("initContainers", pod)
                self.assertNotIn(OWNER, json.dumps(pod))
                server = pod["containers"][0]
                self.assertIn(RUNTIME, secrets(server))
                self.assertFalse(named(self.rendered["apps", environment], "ServiceAccount", "trove-server")
                                 ["automountServiceAccountToken"])

    def test_one_bounded_job_runs_schema_before_grants_with_separate_credentials(self):
        for environment in ("dev", "prod"):
            with self.subTest(environment=environment):
                job = named(self.rendered["apps", environment], "Job", "trove-database-operator")
                self.assertEqual(job["spec"]["backoffLimit"], 1)
                self.assertEqual(job["spec"]["activeDeadlineSeconds"], 300)
                pod = job["spec"]["template"]["spec"]
                self.assertEqual(pod["restartPolicy"], "Never")
                self.assertFalse(pod["automountServiceAccountToken"])
                self.assertEqual(pod["serviceAccountName"], "trove-database-operator")
                self.assertTrue(pod["securityContext"]["runAsNonRoot"])
                self.assertEqual(len(pod["initContainers"]), 1)
                self.assertEqual(len(pod["containers"]), 1)
                initialize, grant = pod["initContainers"][0], pod["containers"][0]
                self.assertEqual(initialize["command"], ["./TroveServer", "migrate", "--yes"])
                self.assertEqual(grant["command"], ["bash", "/operator/grant-runtime.sh"])
                self.assertEqual(secrets(initialize), {OWNER})
                self.assertEqual(secrets(grant), {OWNER, RUNTIME})
                server = named(self.rendered["apps", environment], "Deployment", "trove-server")
                self.assertEqual(initialize["image"], server["spec"]["template"]["spec"]["containers"][0]["image"])
                for container in (initialize, grant):
                    self.assertFalse(container["securityContext"]["allowPrivilegeEscalation"])
                    self.assertEqual(container["securityContext"]["capabilities"]["drop"], ["ALL"])

    def test_sync_dependencies_precede_job_and_serving_follows_it(self):
        for environment in ("dev", "prod"):
            documents = self.rendered["apps", environment]
            job = named(documents, "Job", "trove-database-operator")
            annotations = job["metadata"]["annotations"]
            self.assertEqual(annotations["argocd.argoproj.io/hook"], "Sync")
            self.assertEqual(annotations["argocd.argoproj.io/hook-delete-policy"], "BeforeHookCreation")
            job_wave = int(annotations["argocd.argoproj.io/sync-wave"])
            volumes = job["spec"]["template"]["spec"]["volumes"]
            code_name = next(volume for volume in volumes if volume["name"] == "operator")["configMap"]["name"]
            for kind, name in (("ConfigMap", "trove-server-config"), ("ConfigMap", code_name),
                               ("ServiceAccount", "trove-database-operator")):
                resource = named(documents, kind, name)
                self.assertLess(int(resource["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"]), job_wave)
            server = named(documents, "Deployment", "trove-server")
            self.assertGreater(int(server["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"]), job_wave)
            code = named(documents, "ConfigMap", code_name)["data"]
            for filename in ("grant-runtime.sh", "grant-runtime.sql"):
                self.assertEqual(code[filename], (ROOT / "database-operator" / filename).read_text())

    def test_production_requires_tls_and_development_points_at_one_authority(self):
        production = named(self.rendered["apps", "prod"], "ConfigMap", "trove-server-config")["data"]
        self.assertEqual(production["APP_ENVIRONMENT"], "production")
        self.assertEqual(production["LOG_LEVEL"], "warning")
        self.assertEqual(production["PGSSLMODE"], "verify-full")
        self.assertTrue(production["KEYCLOAK_URL"].startswith("https://"))
        self.assertTrue(production["KEYCLOAK_ISSUER"].startswith("https://"))
        development = named(self.rendered["apps", "dev"], "ConfigMap", "trove-server-config")["data"]
        self.assertEqual(development["DATABASE_HOST"], "trove-timescale")
        self.assertEqual(development["PGSSLMODE"], "disable")
        clusters = [item["metadata"]["name"] for item in self.rendered["infrastructure", "dev"]
                    if item["kind"] == "Cluster"]
        self.assertEqual(clusters, ["keycloak-db"])

    def test_development_authority_and_object_store_use_retained_claims_and_pinned_images(self):
        documents = self.rendered["infrastructure", "dev"]
        for name in ("trove-timescale", "seaweedfs"):
            with self.subTest(name=name):
                store = named(documents, "StatefulSet", name)["spec"]
                self.assertEqual(store["persistentVolumeClaimRetentionPolicy"],
                                 {"whenDeleted": "Retain", "whenScaled": "Retain"})
                self.assertEqual(store["volumeClaimTemplates"][0]["spec"]["accessModes"], ["ReadWriteOnce"])
                self.assertNotIn("emptyDir", json.dumps(store))
                self.assertRegex(store["template"]["spec"]["containers"][0]["image"], r"@sha256:[a-f0-9]{64}$")

    def test_production_database_trust_mounts_exclude_ca_private_keys(self):
        for layer, kind, name, secret in (
            ("apps", "Deployment", "trove-server", "trove-db-ca"),
            ("apps", "Job", "trove-database-operator", "trove-db-ca"),
            ("infrastructure", "Deployment", "keycloak", "keycloak-db-ca"),
        ):
            with self.subTest(workload=name):
                pod = named(self.rendered[layer, "prod"], kind, name)["spec"]["template"]["spec"]
                volume = next(item for item in pod["volumes"] if item["name"] == "database-ca")
                self.assertEqual(volume["secret"], {
                    "secretName": secret, "items": [{"key": "ca.crt", "path": "ca.crt"}],
                })
                for container in pod.get("initContainers", []) + pod["containers"]:
                    mount = next(item for item in container["volumeMounts"] if item["name"] == "database-ca")
                    self.assertEqual(mount, {
                        "name": "database-ca", "mountPath": "/run/secrets/database", "readOnly": True,
                    })
        config = named(self.rendered["apps", "prod"], "ConfigMap", "trove-server-config")["data"]
        self.assertEqual(config["TLS_CA_FILE"], "/run/secrets/database/ca.crt")
        job = named(self.rendered["apps", "prod"], "Job", "trove-database-operator")["spec"]["template"]["spec"]
        for container, variable in ((job["initContainers"][0], "TLS_CA_FILE"),
                                    (job["containers"][0], "PGSSLROOTCERT")):
                self.assertEqual(next(item["value"] for item in container["env"] if item["name"] == variable),
                             "/run/secrets/database/ca.crt")

    def test_production_database_has_matching_pinned_engine_and_extension(self):
        documents = self.rendered["infrastructure", "prod"]
        database = named(documents, "Cluster", "trove-db")["spec"]
        identity = named(documents, "Cluster", "keycloak-db")["spec"]
        self.assertEqual(database["imageName"], identity["imageName"])
        self.assertRegex(database["imageName"], r"postgresql:18\.6-minimal-trixie@sha256:[a-f0-9]{64}$")
        self.assertFalse(database["enableSuperuserAccess"])
        engine = database["postgresql"]
        self.assertEqual(engine["shared_preload_libraries"], ["timescaledb"])
        self.assertEqual(engine["parameters"]["timescaledb.telemetry_level"], "off")
        self.assertEqual(len(engine["extensions"]), 1)
        extension = engine["extensions"][0]
        self.assertEqual(extension["name"], "timescaledb-oss")
        self.assertRegex(extension["image"]["reference"], r"timescaledb-oss:2\.29\.2-18-trixie@sha256:[a-f0-9]{64}$")
        self.assertNotIn("extensions", identity.get("postgresql", {}))
        installation = named(documents, "Database", "trove")["spec"]
        self.assertEqual(installation["cluster"], {"name": "trove-db"})
        self.assertEqual(installation["owner"], database["bootstrap"]["initdb"]["owner"])
        self.assertEqual(installation["extensions"], [{"name": "timescaledb", "version": "2.29.2"}])
        self.assertFalse(any(item["kind"] == "Database" for item in self.rendered["infrastructure", "dev"]))

    def test_only_the_schema_owner_can_provision_runtime_roles(self):
        database = named(self.rendered["infrastructure", "prod"], "Cluster", "trove-db")["spec"]
        self.assertNotIn("managed", database)
        self.assertEqual(database["bootstrap"]["initdb"]["postInitApplicationSQL"], [
            "ALTER ROLE trove CREATEROLE", "GRANT pg_read_all_settings TO trove",
        ])
        chart = yaml.safe_load((ROOT / "argocd-apps/base/cnpg-operator.yaml").read_text())
        self.assertEqual(chart["spec"]["source"]["targetRevision"], "0.29.0")
        self.assertRegex(chart["spec"]["source"]["helm"]["valuesObject"]["image"]["tag"],
                         r"^1\.30\.0@sha256:[a-f0-9]{64}$")

    def test_production_identity_tls_is_consistent(self):
        documents = self.rendered["infrastructure", "prod"]
        container = named(documents, "Deployment", "keycloak")["spec"]["template"]["spec"]["containers"][0]
        env = {item["name"]: item.get("value") for item in container["env"]}
        self.assertEqual(env["KC_HTTP_ENABLED"], "false")
        self.assertEqual(env["KC_HOSTNAME_STRICT"], "true")
        self.assertEqual(env["KC_DB_TLS_MODE"], "verify-server")
        self.assertEqual(env["KC_DB_TLS_TRUST_STORE_FILE"], "/run/secrets/database/ca.crt")
        self.assertEqual(container["ports"], [{"name": "https", "containerPort": 8443}])
        service = named(documents, "Service", "keycloak")["spec"]["ports"]
        self.assertEqual([(port["port"], port["targetPort"]) for port in service], [(8443, 8443)])
        backend = named(documents, "IngressRoute", "auth-ingress")["spec"]["routes"][0]["services"][0]
        self.assertEqual(backend["name"], "keycloak")
        self.assertEqual(backend["port"], 8443)
        self.assertEqual(backend["scheme"], "https")
        transport = named(documents, "ServersTransport", backend["serversTransport"])["spec"]
        self.assertEqual(transport, {"serverName": "console.troveplatform.org", "insecureSkipVerify": False})
        importer = named(documents, "Job", "keycloak-config-cli")["spec"]["template"]["spec"]
        self.assertFalse(importer["automountServiceAccountToken"])
        importer_env = {item["name"]: item.get("value") for item in importer["containers"][0]["env"]}
        self.assertEqual(importer_env["KEYCLOAK_SSLVERIFY"], "true")
        config = named(self.rendered["apps", "prod"], "ConfigMap", "trove-server-config")["data"]
        self.assertEqual(importer_env["KEYCLOAK_URL"], config["KEYCLOAK_URL"])
        self.assertEqual(config["KEYCLOAK_URL"], env["KC_HOSTNAME"])
        dev = named(self.rendered["infrastructure", "dev"], "Service", "keycloak")
        self.assertEqual(dev["spec"]["ports"][0]["targetPort"], 8080)

    def test_application_https_identity_is_only_mounted_in_production_serving_pods(self):
        documents = self.rendered["apps", "prod"]
        pod = named(documents, "Deployment", "trove-server")["spec"]["template"]["spec"]
        container = pod["containers"][0]
        identity = next(item for item in pod["volumes"] if item["name"] == "serving-identity")
        self.assertEqual(identity["secret"], {
            "secretName": "trove-main-tls-secret",
            "items": [{"key": "tls.crt", "path": "tls.crt"}, {"key": "tls.key", "path": "tls.key"}],
        })
        mount = next(item for item in container["volumeMounts"] if item["name"] == "serving-identity")
        self.assertEqual(mount, {"name": "serving-identity", "mountPath": "/run/secrets/https", "readOnly": True})
        for probe in ("startupProbe", "readinessProbe", "livenessProbe"):
            self.assertEqual(container[probe]["httpGet"], {
                "path": "/api/v0/health", "port": 8080, "scheme": "HTTPS",
            })
        config = named(documents, "ConfigMap", "trove-server-config")["data"]
        self.assertEqual(config["TLS_CERTIFICATE_FILE"], "/run/secrets/https/tls.crt")
        self.assertEqual(config["TLS_PRIVATE_KEY_FILE"], "/run/secrets/https/tls.key")
        route = named(self.rendered["infrastructure", "prod"], "IngressRoute", "trove-ingress")
        backend = route["spec"]["routes"][1]["services"][0]
        self.assertEqual(backend["name"], "trove-server-service")
        self.assertEqual(backend["port"], 8080)
        self.assertEqual(backend["scheme"], "https")
        self.assertEqual(backend["serversTransport"], "platform-https")
        for environment in ("dev", "prod"):
            operator = named(self.rendered["apps", environment], "Job", "trove-database-operator")
            self.assertNotIn("trove-main-tls-secret", json.dumps(operator))
            self.assertNotIn("TLS_PRIVATE_KEY_FILE", json.dumps(operator))
        dev = named(self.rendered["apps", "dev"], "Deployment", "trove-server")
        self.assertNotIn("serving-identity", json.dumps(dev))
        self.assertNotIn("HTTPS", json.dumps(dev))

    def test_dashboard_transport_is_secure_by_default_and_development_is_explicit(self):
        for environment, scheme in (("prod", "HTTPS"), ("dev", "HTTP")):
            with self.subTest(environment=environment):
                documents = self.rendered["apps", environment]
                config = named(documents, "ConfigMap", "trove-web-config")["data"]
                self.assertEqual(config["APP_ENVIRONMENT"], "production" if environment == "prod" else "development")
                pod = named(documents, "Deployment", "trove-web")["spec"]["template"]["spec"]
                container = pod["containers"][0]
                self.assertEqual(container["securityContext"]["runAsUser"], 101)
                self.assertEqual(container["securityContext"]["runAsGroup"], 101)
                self.assertTrue(container["securityContext"]["runAsNonRoot"])
                self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
                self.assertEqual(pod["securityContext"]["fsGroup"], 101)
                cache = next(item for item in pod["volumes"] if item["name"] == "nginx-cache")
                self.assertEqual(cache["emptyDir"], {"medium": "Memory", "sizeLimit": "16Mi"})
                self.assertNotIn(OWNER, json.dumps(pod))
                self.assertNotIn(RUNTIME, json.dumps(pod))
                for probe in ("startupProbe", "readinessProbe", "livenessProbe"):
                    check = container[probe]["httpGet"]
                    self.assertEqual(check["port"], 8080)
                    self.assertEqual(check["path"], "/")
                    self.assertEqual(check.get("scheme", "HTTP"), scheme)
        pod = named(self.rendered["apps", "prod"], "Deployment", "trove-web")["spec"]["template"]["spec"]
        self.assertEqual({item["name"] for item in pod["volumes"]}, {"serving-identity", "nginx-cache"})
        identity = next(item for item in pod["volumes"] if item["name"] == "serving-identity")
        self.assertEqual(identity, {"name": "serving-identity", "secret": {
            "secretName": "trove-main-tls-secret",
            "items": [{"key": "tls.crt", "path": "tls.crt"}, {"key": "tls.key", "path": "tls.key"}],
        }})
        mount = next(item for item in pod["containers"][0]["volumeMounts"] if item["name"] == "serving-identity")
        self.assertEqual(mount, {
            "name": "serving-identity", "mountPath": "/run/secrets/https", "readOnly": True,
        })
        for environment in ("dev", "prod"):
            route = named(self.rendered["infrastructure", environment], "IngressRoute", "trove-ingress")
            backend = route["spec"]["routes"][0]["services"][0]
            expected = {"name": "trove-web-service", "port": 80}
            if environment == "prod":
                expected.update(scheme="https", serversTransport="platform-https")
            self.assertEqual(backend, expected)

    def test_identity_network_rules_match_tls_routes_and_limit_public_egress(self):
        documents = self.rendered["infrastructure", "prod"]
        values = yaml.safe_load((ROOT / "argocd-apps/prod/traefik-values.yaml").read_text())
        address = values["service"]["spec"]["loadBalancerIP"]
        for name in ("allow-server-to-keycloak-egress", "allow-config-cli-to-keycloak-egress"):
            policy = named(documents, "NetworkPolicy", name)["spec"]
            self.assertEqual(policy["egress"], [{"to": [{"ipBlock": {"cidr": f"{address}/32"}}],
                                                "ports": [{"protocol": "TCP", "port": 443}]}])
        names = {item["metadata"]["name"] for item in documents if item["kind"] == "NetworkPolicy"}
        self.assertNotIn("allow-server-to-keycloak", names)
        self.assertNotIn("allow-config-cli-to-keycloak", names)
        ingress = named(documents, "NetworkPolicy", "allow-traefik-to-keycloak")["spec"]["ingress"]
        self.assertEqual(ingress[0]["ports"], [{"protocol": "TCP", "port": 8443}])
        egress = named(documents, "NetworkPolicy", "allow-traefik-egress")["spec"]["egress"]
        self.assertEqual(egress[0]["to"][0]["podSelector"]["matchExpressions"][0]["values"],
                         ["trove-server", "trove-web"])
        self.assertIn({"to": [{"podSelector": {"matchLabels": {"app": "keycloak"}}}],
                       "ports": [{"protocol": "TCP", "port": 8443}]}, egress)

    def test_ingress_access_logs_exclude_headers_urls_and_participant_identifiers(self):
        for environment in ("dev", "prod"):
            values = yaml.safe_load((ROOT / f"argocd-apps/{environment}/traefik-values.yaml").read_text())
            self.assertEqual(values["logs"]["general"]["level"], "WARN")
            access = values["logs"]["access"]
            self.assertTrue(access["enabled"])
            self.assertEqual(access["format"], "json")
            self.assertEqual(access["fields"]["headers"], {"defaultmode": "drop"})
            self.assertEqual(access["fields"]["general"], {
                "defaultmode": "drop",
                "names": dict.fromkeys(("StartUTC", "RequestMethod", "DownstreamStatus", "Duration",
                                        "RouterName", "ServiceName"), "keep"),
            })

    def test_runtime_secret_is_distinct_and_production_secrets_have_no_seed_values(self):
        for environment in ("dev", "prod"):
            documents = self.rendered["infrastructure", environment]
            owner = named(documents, "ExternalSecret", OWNER)
            runtime = named(documents, "ExternalSecret", RUNTIME)
            self.assertNotEqual(owner["spec"]["data"][0]["remoteRef"]["key"],
                                runtime["spec"]["data"][0]["remoteRef"]["key"])
        source = (ROOT / "terraform/secrets.tf").read_text()
        self.assertIn('"server-runtime-db-credentials"', source)
        self.assertNotIn('resource "google_secret_manager_secret_version"', source)
        self.assertNotIn("secret_data", source)

    def test_object_store_readiness_waits_for_the_s3_endpoint_not_only_the_master(self):
        store = named(self.rendered["infrastructure", "dev"], "StatefulSet", "seaweedfs")
        container = store["spec"]["template"]["spec"]["containers"][0]
        for probe in ("startupProbe", "readinessProbe"):
            self.assertEqual(container[probe]["httpGet"], {"path": "/", "port": "s3"})
            self.assertEqual(container[probe]["timeoutSeconds"], 3)

    def test_operator_egress_is_not_given_the_serving_apps_identity(self):
        documents = self.rendered["infrastructure", "dev"]
        policy = named(documents, "NetworkPolicy", "allow-operator-to-timescale")["spec"]
        self.assertEqual(policy["podSelector"]["matchLabels"], {"app": "trove-database-operator"})
        self.assertEqual(policy["egress"], [{"to": [{"podSelector": {"matchLabels": {"app": "trove-timescale"}}}],
                                          "ports": [{"protocol": "TCP", "port": 5432}]}])
        job = named(self.rendered["apps", "dev"], "Job", "trove-database-operator")
        self.assertEqual(job["spec"]["template"]["metadata"]["labels"]["app"], "trove-database-operator")

    def test_compose_development_ports_are_loopback_only_and_storage_matches_kubernetes(self):
        services = yaml.safe_load((ROOT / "docker/docker-compose.yml").read_text())["services"]
        for name, service in services.items():
            for port in service.get("ports", []):
                with self.subTest(service=name, port=port):
                    self.assertTrue(port.startswith("127.0.0.1:"))
        store = named(self.rendered["infrastructure", "dev"], "StatefulSet", "seaweedfs")
        self.assertEqual(services["seaweedfs"]["image"], store["spec"]["template"]["spec"]["containers"][0]["image"])
        self.assertEqual(services["seaweedfs"]["ports"], ["127.0.0.1:8333:8333"])
        self.assertIn("http://127.0.0.1:8333/", services["seaweedfs"]["healthcheck"]["test"][1])
