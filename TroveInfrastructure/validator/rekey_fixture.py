"""TEST ONLY: bind a synthetic exchange fixture with the pinned IG identity implementation."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import argparse
import copy
import json
from pathlib import Path
import sys


def rekey(bundle, *, event_system, producer_instance, participant_system, participant_value, effective_at, sequence):
    from Scripts.exchange_protocol import derive_hmac_identity, entry_full_url, entry_node_identity, event_identity
    patient = next(entry["resource"] for entry in bundle["entry"] if entry["resource"]["resourceType"] == "Patient")
    original_participant = patient["identifier"][0]

    def transform(value):
        if isinstance(value, dict):
            if value.get("system") == original_participant["system"] and value.get("value") == original_participant["value"]:
                value["system"] = participant_system
                value["value"] = participant_value
            for key, child in value.items():
                if key in ("effectiveDateTime", "issued", "recorded", "timestamp", "authored") and isinstance(child, str):
                    value[key] = effective_at
                elif isinstance(child, str):
                    value[key] = child.replace("https://study.example.org", "https://study.trove.test")
                else:
                    transform(child)
        elif isinstance(value, list):
            for child in value:
                transform(child)

    # Copy the identity before changing its first occurrence in Patient.
    original_participant = copy.deepcopy(original_participant)
    transform(bundle)
    event = bundle["identifier"]
    event["system"] = event_system
    event["value"] = event_identity(producer_instance, sequence)
    replacements = {}
    for entry in bundle["entry"]:
        key = entry["extension"][0]["valueIdentifier"]
        role = key["type"]["coding"][0]["code"]
        if role == "entry-node":
            parts = key["value"].split(":")
            key["value"] = entry_node_identity(event_system=event_system, event_value=event["value"],
                                                role=parts[1], ordinal=int(parts[2]))
        elif role == "device-snapshot":
            key["value"] = derive_hmac_identity(
                key=bytes(range(32)), key_id="test-key", epoch=1, identity_kind="device-snapshot",
                components=[event_system, event["value"], "application", "fixture-app"],
            )
            entry["resource"]["identifier"] = [copy.deepcopy(key)]
        full_url = entry_full_url(key["system"], key["value"])
        replacements[entry["fullUrl"]] = full_url
        entry["fullUrl"] = full_url

    def references(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if key == "reference" and isinstance(child, str) and child in replacements:
                    value[key] = replacements[child]
                else:
                    references(child)
        elif isinstance(value, list):
            for child in value:
                references(child)

    references(bundle)
    return bundle


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets", type=Path, required=True, help="Verified prepare.py output assets directory")
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--event-system", required=True)
    parser.add_argument("--producer-instance", required=True)
    parser.add_argument("--participant-system", required=True)
    parser.add_argument("--participant-value", required=True)
    parser.add_argument("--effective-at", required=True)
    parser.add_argument("--sequence", type=int, default=50)
    args = parser.parse_args()
    sys.path.insert(0, str(args.assets / "grove-fhir"))
    bundle = json.loads(args.fixture.read_bytes())
    result = rekey(bundle, event_system=args.event_system, producer_instance=args.producer_instance,
                   participant_system=args.participant_system, participant_value=args.participant_value,
                   effective_at=args.effective_at, sequence=args.sequence)
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
