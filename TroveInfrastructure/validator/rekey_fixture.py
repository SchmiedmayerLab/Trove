"""TEST ONLY: bind a synthetic record with the pinned IG identity implementation."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import argparse
import copy
from datetime import datetime, timedelta
from pathlib import Path
import sys


def rekey(bundle, *, participant_system, participant_value, effective_at, sequence,
          identifier_root, registration_id, preserve_recorded=False, native_record_id=None):
    # The synthetic sequence varies the conversion instant; it never enters a source-record
    # or source-output identity.
    from Scripts.canonical_json import JSONNumber
    from Scripts.exchange_fixtures import role_of
    from Scripts.exchange_protocol import derive_hmac_identity
    patient = next((entry["resource"] for entry in bundle["entry"] if entry["resource"]["resourceType"] == "Patient"), None)
    original_participant = (next(value for value in patient["identifier"] if role_of(value) is None)
                            if patient is not None else None)
    original_participant = copy.deepcopy(original_participant)
    recorded = (datetime.fromisoformat(effective_at.replace("Z", "+00:00")) + timedelta(milliseconds=sequence)).isoformat(
        timespec="milliseconds").replace("+00:00", "Z")

    def transform(value):
        if isinstance(value, dict):
            role = role_of(value) if isinstance(value.get("type"), dict) else None
            if role:
                value["system"] = f"{identifier_root.rstrip('/')}/NamingSystem/grove-{role}-v0/{registration_id}/1"
                prefix, _, epoch, digest = value["value"].split(":", 3)
                value["value"] = f"{prefix}:{registration_id}:{epoch}:{digest}"
                if native_record_id is not None and role in ("source-record", "source-output"):
                    components = ["synthetic", "heart-rate", identifier_root + "/fixture-repository", registration_id, native_record_id]
                    if role == "source-output":
                        components += ["primary", digest]
                    value["value"] = derive_hmac_identity(
                        key=bytes(range(32)), key_id=registration_id, epoch=1,
                        identity_kind=role, components=components,
                    )
            if original_participant is not None and all(value.get(k) == original_participant[k] for k in ("system", "value")):
                value["system"], value["value"] = participant_system, participant_value
            for key, child in value.items():
                if key in ("recorded", "timestamp") and isinstance(child, str):
                    if not preserve_recorded:
                        value[key] = recorded
                elif key in ("effectiveDateTime", "issued", "authored", "occurredDateTime") and isinstance(child, str):
                    value[key] = effective_at
                elif isinstance(child, str) and not isinstance(child, JSONNumber):
                    value[key] = child.replace("https://study.example.org", "https://study.trove.test")
                else:
                    transform(child)
        elif isinstance(value, list):
            for child in value:
                transform(child)

    transform(bundle)
    bundle.pop("identifier", None)
    return key_content(bundle, identifier_root, registration_id, (participant_system, participant_value))


def key_content(bundle, root, key_id, subject):
    from Scripts.exchange_fixtures import (
        ACTIVE_BUNDLE_PROFILE, CONTEXT_NODE_ROLES, DEVICE_NODE_ROLES, ENTRY_KEY_EXTENSION,
        rewrite_references, role_of, typed,
    )
    from Scripts.exchange_protocol import (
        CONTEXT_SNAPSHOT_EXTENSION, IDENTIFIER_ROLE_SYSTEM, RECORD_VERSION_EXTENSION,
        content_digest, context_snapshot_identity, device_snapshot_identity, entry_full_url,
        record_content_digest, record_outputs, record_retraction_identity, record_version_identity,
    )
    scope = dict(key=bytes(range(32)), key_id=key_id, epoch=1)

    def identity(role, value):
        return {"type": {"coding": [{"system": IDENTIFIER_ROLE_SYSTEM, "code": role}]},
                "system": f"{root.rstrip('/')}/NamingSystem/grove-{role}-v0/{key_id}/1", "value": value}

    def extension(resource, url, identifier):
        values = resource.setdefault("extension", [])
        values[:] = [value for value in values if value.get("url") != url]
        values.append({"url": url, "valueIdentifier": copy.deepcopy(identifier)})

    for _ in range(16):
        moved = False
        for entry in bundle["entry"]:
            resource = entry["resource"]
            kind = resource["resourceType"]
            if kind == "Device" or kind in CONTEXT_NODE_ROLES or kind == "QuestionnaireResponse":
                if kind == "Device":
                    node_role = next(DEVICE_NODE_ROLES[p] for p in resource["meta"]["profile"] if p in DEVICE_NODE_ROLES)
                    derive, role = device_snapshot_identity, "device-snapshot"
                else:
                    node_role = "questionnaire-response" if kind == "QuestionnaireResponse" else CONTEXT_NODE_ROLES[kind]
                    derive, role = context_snapshot_identity, "context-snapshot"
                key = identity(role, derive(**scope, subject_system=subject[0], subject_value=subject[1],
                                           node_role=node_role, content_digest=content_digest(resource)))
                if kind == "QuestionnaireResponse":
                    extension(resource, CONTEXT_SNAPSHOT_EXTENSION, key)
                else:
                    identifiers = resource.setdefault("identifier", [])
                    identifiers[:] = [value for value in identifiers if role_of(value) != role]
                    identifiers.append(copy.deepcopy(key))
            elif kind == "Provenance":
                source = resource["entity"][0]["what"]["identifier"]
                arguments = dict(**scope, source_record_system=source["system"], source_record_value=source["value"])
                if ACTIVE_BUNDLE_PROFILE in bundle["meta"]["profile"]:
                    key = identity("record-version", record_version_identity(
                        **arguments, record_content_digest=record_content_digest(resource, record_outputs(bundle, resource))))
                    extension(resource, RECORD_VERSION_EXTENSION, key)
                else:
                    key = identity("record-retraction", record_retraction_identity(**arguments))
            else:
                key = typed(resource, "source-output") or typed(resource, "source-artifact")
                if key is None:
                    raise ValueError("Synthetic fixture output has no logical identity")
            entry["extension"] = [{"url": ENTRY_KEY_EXTENSION, "valueIdentifier": copy.deepcopy(key)}]
            previous = entry["fullUrl"]
            entry["fullUrl"] = entry_full_url(key["system"], key["value"])
            if previous != entry["fullUrl"]:
                rewrite_references(bundle, {previous: entry["fullUrl"]})
                moved = True
        if not moved:
            return bundle
    raise ValueError("Synthetic fixture content identities did not converge")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets", type=Path, required=True, help="Verified prepare.py output assets directory")
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--identifier-root", required=True)
    parser.add_argument("--registration-id", required=True)
    parser.add_argument("--participant-system", required=True)
    parser.add_argument("--participant-value", required=True)
    parser.add_argument("--effective-at", required=True)
    parser.add_argument("--sequence", type=int, default=50)
    parser.add_argument("--native-record-id", help="Independent synthetic native record; sequence still selects only a revision")
    args = parser.parse_args()
    sys.path.insert(0, str(args.assets / "grove-fhir"))
    from Scripts.canonical_json import canonical_bytes, loads_lossless
    result = rekey(loads_lossless(args.fixture.read_bytes()),
                   participant_system=args.participant_system, participant_value=args.participant_value,
                   effective_at=args.effective_at, sequence=args.sequence,
                   identifier_root=args.identifier_root, registration_id=args.registration_id, native_record_id=args.native_record_id)
    sys.stdout.buffer.write(canonical_bytes(result))


if __name__ == "__main__":
    main()
