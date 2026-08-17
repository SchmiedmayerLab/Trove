#!/usr/bin/env python3
#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Generate the deterministic HealthKit-shaped FHIR workload used by the thesis."""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import json
import sys
import uuid


PARTICIPANT_NAMESPACE = uuid.UUID("d8dffab2-7164-4df7-84cf-347970444aa8")
LOINC_SYSTEM = "http://loinc.org"
HEALTHKIT_SYSTEM = "https://developer.apple.com/documentation/healthkit"


@dataclass(frozen=True)
class SampleProfile:
    healthkit_identifier: str
    loinc_code: str
    display: str
    cadence_minutes: int
    unit: str
    unit_code: str
    base_value: float


PROFILES = (
    SampleProfile("HKQuantityTypeIdentifierHeartRate", "8867-4", "Heart rate", 1, "beats/minute", "/min", 72.0),
    SampleProfile(
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
        "80404-7",
        "Heart rate variability SDNN",
        5,
        "milliseconds",
        "ms",
        42.0,
    ),
    SampleProfile("HKQuantityTypeIdentifierStepCount", "55423-8", "Step count", 15, "count", "{count}", 240.0),
    SampleProfile(
        "HKQuantityTypeIdentifierOxygenSaturation",
        "59408-5",
        "Oxygen saturation",
        30,
        "percent",
        "%",
        97.0,
    ),
    SampleProfile("HKQuantityTypeIdentifierBodyMass", "29463-7", "Body weight", 1440, "kilograms", "kg", 75.0),
)


def participant_id(index: int) -> uuid.UUID:
    return uuid.uuid5(PARTICIPANT_NAMESPACE, f"participant-{index:03d}")


def expected_row_count(participants: int, days: int) -> int:
    samples_per_day = sum(1440 // profile.cadence_minutes for profile in PROFILES)
    return participants * days * samples_per_day


def observation_json(
    participant: uuid.UUID,
    profile: SampleProfile,
    sample_time: datetime,
    sample_index: int,
    external_id: str,
    payload_bytes: int,
) -> tuple[str, float]:
    value = round(profile.base_value + ((sample_index % 21) - 10) / 10, 2)
    zones = (
        (timedelta(hours=-8), "America/Los_Angeles"),
        (timedelta(hours=-5), "America/New_York"),
        (timedelta(0), "UTC"),
        (timedelta(hours=1), "Europe/Berlin"),
        (timedelta(hours=5, minutes=30), "Asia/Kolkata"),
    )
    offset, zone_name = zones[participant.int % len(zones)]
    local_time = sample_time.astimezone(timezone(offset))
    effective_time = (
        local_time.strftime("%Y-%m-%dT%H:%M:%S")
        + f".{sample_index % 1_000_000_000:09d}"
        + local_time.strftime("%z")
    )
    effective_time = f"{effective_time[:-2]}:{effective_time[-2:]}"
    resource = {
        "resourceType": "Observation",
        "id": external_id,
        "meta": {"profile": ["https://example.org/fhir/StructureDefinition/healthkit-observation"]},
        "status": "final",
        "category": [
            {
                "coding": [
                    {
                        "system": "http://terminology.hl7.org/CodeSystem/observation-category",
                        "code": "activity",
                        "display": "Activity",
                    }
                ]
            }
        ],
        "code": {
            "coding": [
                {"system": LOINC_SYSTEM, "code": profile.loinc_code, "display": profile.display},
                {
                    "system": HEALTHKIT_SYSTEM,
                    "code": profile.healthkit_identifier,
                    "display": profile.display,
                },
            ],
            "text": profile.display,
        },
        "subject": {"reference": f"Patient/{participant}"},
        "effectiveDateTime": effective_time,
        "issued": sample_time.isoformat(timespec="microseconds").replace("+00:00", "Z"),
        "valueQuantity": {
            "value": value,
            "unit": profile.unit,
            "system": "http://unitsofmeasure.org",
            "code": profile.unit_code,
        },
        "device": {"display": "Apple Watch"},
        "extension": [
            {
                "url": "https://example.org/fhir/StructureDefinition/sourceDevice",
                "extension": [
                    {"url": "manufacturer", "valueString": "Apple Inc."},
                    {"url": "model", "valueString": "Watch"},
                    {"url": "hardwareVersion", "valueString": "Watch7,5"},
                    {"url": "softwareVersion", "valueString": "11.5"},
                    {"url": "localIdentifier", "valueString": str(participant)},
                ],
            },
            {
                "url": "https://example.org/fhir/StructureDefinition/sourceRevision",
                "extension": [
                    {"url": "sourceVersion", "valueString": "11.5"},
                    {"url": "productType", "valueString": "Watch7,5"},
                    {"url": "operatingSystemVersion", "valueString": "11.5.0"},
                ],
            },
            {
                "url": "https://example.org/fhir/StructureDefinition/sampleUploadTimeZone",
                "valueString": zone_name,
            },
        ],
    }
    resource["note"] = [{"text": ""}]
    compact = json.dumps(resource, separators=(",", ":"), sort_keys=True)
    padding = max(0, payload_bytes - len(compact.encode("utf-8")))
    resource["note"][0]["text"] = "x" * padding
    return json.dumps(resource, separators=(",", ":"), sort_keys=True), value


def generate_rows(participants: int, days: int, start: datetime, payload_bytes: int):
    for participant_index in range(participants):
        participant = participant_id(participant_index)
        for profile in PROFILES:
            sample_count = days * 1440 // profile.cadence_minutes
            cadence = timedelta(minutes=profile.cadence_minutes)
            for sample_index in range(sample_count):
                sample_time = start + sample_index * cadence
                external_id = f"p{participant_index:03d}-{profile.loinc_code}-{sample_index:06d}"
                resource, value = observation_json(
                    participant,
                    profile,
                    sample_time,
                    sample_index,
                    external_id,
                    payload_bytes,
                )
                yield (
                    str(participant),
                    "Observation",
                    sample_time.isoformat(timespec="microseconds"),
                    external_id,
                    profile.loinc_code,
                    LOINC_SYSTEM,
                    value,
                    profile.unit_code,
                    "http://unitsofmeasure.org",
                    resource,
                )


def parse_start(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--participants", type=int, default=200)
    parser.add_argument("--days", type=int, default=30)
    parser.add_argument("--start", default="2025-01-01T00:00:00Z")
    parser.add_argument("--payload-bytes", type=int, default=2560)
    args = parser.parse_args()
    if args.participants < 1 or args.days < 1 or args.payload_bytes < 512:
        parser.error("participants and days must be positive; payload-bytes must be at least 512")

    writer = csv.writer(sys.stdout, lineterminator="\n")
    writer.writerows(generate_rows(args.participants, args.days, parse_start(args.start), args.payload_bytes))


if __name__ == "__main__":
    main()
