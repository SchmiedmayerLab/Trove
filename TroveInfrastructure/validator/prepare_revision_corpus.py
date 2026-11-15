"""Bind the pinned revision corpus to a synthetic enrollment without changing its ordering evidence."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import argparse
import base64
import copy
import hashlib
import json
from pathlib import Path
import sys

from rekey_fixture import rekey


def prepare(root, *, participant_system, participant_value, effective_at, identifier_root, registration_id):
    from Scripts.canonical_json import canonical_bytes, loads_lossless
    from Scripts.receiver_lifecycle_fixtures import revision_sequences

    declared = json.loads((root / "revision-sequences.json").read_bytes())
    if declared["schemaVersion"] != 0 or declared["bundles"] != "bundles.json" or len(declared["sequences"]) != 43:
        raise ValueError("Update the explicit receiver acceptance matrix for this corpus")
    index = json.loads((root / "bundles.json").read_bytes())["bundles"]
    original = {}
    for name in declared["recordVersions"]:
        item = index[name]
        if item["path"] != f"resources/{name}.json" or item["recordVersions"] != [declared["recordVersions"][name]]:
            raise ValueError("Unexpected corpus path or version identity")
        raw = (root / item["path"]).read_bytes()
        if hashlib.sha256(raw).hexdigest() != item["sha256"]:
            raise ValueError("Corpus checksum mismatch")
        original[name] = loads_lossless(raw)
    # The pinned IG supplies the declarative expected states. First establish that its
    # generator reproduces the published corpus before using it for deployment-bound keys.
    if revision_sequences(original) != declared:
        raise ValueError("Published revision expectations differ from the pinned IG generator")
    rebound = {
        name: rekey(copy.deepcopy(bundle), participant_system=participant_system, participant_value=participant_value,
                    effective_at=effective_at, sequence=0, identifier_root=identifier_root,
                    registration_id=registration_id, preserve_recorded=True)
        for name, bundle in original.items()
    }
    expected = revision_sequences(rebound)
    prepared = {}
    selected = set(expected["authorizedOutputs"]["purpose-a"])
    for name, bundle in rebound.items():
        original_recorded = [e["resource"]["recorded"] for e in original[name]["entry"] if e["resource"]["resourceType"] == "Provenance"]
        recorded = [e["resource"]["recorded"] for e in bundle["entry"] if e["resource"]["resourceType"] == "Provenance"]
        if recorded != original_recorded:
            raise ValueError("Binding must preserve the exact recorded lexemes")
        addresses = {alias: value["fullUrl"] for alias, value in expected["outputs"].items() if value["bundle"] == name}
        prepared[name] = {
            "bytesBase64": base64.b64encode(canonical_bytes(bundle)).decode("ascii"),
            "addresses": addresses,
            "selected": sorted(value for alias, value in addresses.items() if alias in selected),
        }
    # Rebinding changes content-derived version identifiers and therefore can reverse
    # the equal-instant identifier tie-break. Use the IG's declared states with only
    # that choice recomputed by its own generator, never Trove's selection implementation.
    return {"corpus": expected, "events": prepared}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--identifier-root", required=True)
    parser.add_argument("--registration-id", required=True)
    parser.add_argument("--participant-system", required=True)
    parser.add_argument("--participant-value", required=True)
    parser.add_argument("--effective-at", required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(args.assets / "grove-fhir"))
    result = prepare(args.corpus, participant_system=args.participant_system, participant_value=args.participant_value,
                     effective_at=args.effective_at, identifier_root=args.identifier_root, registration_id=args.registration_id)
    json.dump(result, sys.stdout, separators=(",", ":"))


if __name__ == "__main__":
    main()
