# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

"""Keep missing or obsolete custom-resource schemas from passing verification."""

import importlib.util
from pathlib import Path
import unittest

import yaml


SPEC = importlib.util.spec_from_file_location(
    "manifest_schemas", Path(__file__).resolve().parents[1] / "prepare-manifest-schemas.py"
)
assert SPEC is not None and SPEC.loader is not None
SCHEMAS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCHEMAS)


class ManifestSchemaTests(unittest.TestCase):
    def test_uses_only_the_served_v1_cluster_store_schema(self) -> None:
        schema = {"type": "object", "properties": {"spec": {"type": "object"}}}
        document = {
            "kind": "CustomResourceDefinition",
            "spec": {
                "group": "external-secrets.io",
                "names": {"kind": "ClusterSecretStore"},
                "versions": [{"name": "v1", "served": True, "schema": {"openAPIV3Schema": schema}}],
            },
        }
        self.assertEqual(SCHEMAS.cluster_store_schema(yaml.safe_dump_all([None, document])), schema)
        for name, served in (("v1beta1", True), ("v1", False)):
            with self.subTest(name=name, served=served):
                document["spec"]["versions"][0].update(name=name, served=served)
                with self.assertRaises(ValueError):
                    SCHEMAS.cluster_store_schema(yaml.safe_dump(document))

    def test_missing_or_invalid_schema_fails(self) -> None:
        for bundle in ("", "null", "kind: ConfigMap", "- scalar"):
            with self.subTest(bundle=bundle), self.assertRaises(ValueError):
                SCHEMAS.cluster_store_schema(bundle)


if __name__ == "__main__":
    unittest.main()
