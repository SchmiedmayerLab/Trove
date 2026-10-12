# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

"""Provide kubeconform with the schemas from the deployed External Secrets release."""

import argparse
import json
from pathlib import Path
import re
import urllib.request

import yaml


ROOT = Path(__file__).resolve().parents[1]


def cluster_store_schema(bundle: str) -> dict[str, object]:
    """Require the exact v1 ClusterSecretStore schema; never skip validation."""
    for document in yaml.safe_load_all(bundle):
        if not isinstance(document, dict) or document.get("kind") != "CustomResourceDefinition":
            continue
        spec = document["spec"]
        if spec["group"] != "external-secrets.io" or spec["names"]["kind"] != "ClusterSecretStore":
            continue
        for version in spec["versions"]:
            if version["name"] == "v1" and version["served"]:
                schema = version["schema"]["openAPIV3Schema"]
                if not isinstance(schema, dict) or schema.get("type") != "object":
                    raise ValueError("Invalid ClusterSecretStore schema")
                return schema
    raise ValueError("The deployed release does not provide ClusterSecretStore v1")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    application = yaml.safe_load((ROOT / "argocd-apps/base/external-secrets-operator.yaml").read_text())
    version = str(application["spec"]["source"]["targetRevision"])
    if re.fullmatch(r"\d+\.\d+\.\d+", version) is None:
        raise ValueError("Expected a pinned External Secrets release")
    url = f"https://raw.githubusercontent.com/external-secrets/external-secrets/v{version}/deploy/crds/bundle.yaml"
    with urllib.request.urlopen(url, timeout=30) as response:
        schema = cluster_store_schema(response.read().decode("utf-8"))
    destination = args.output / "external-secrets.io"
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "clustersecretstore_v1.json").write_text(json.dumps(schema) + "\n")
    print(f"Prepared ClusterSecretStore v1 schema from External Secrets {version}")


if __name__ == "__main__":
    main()
