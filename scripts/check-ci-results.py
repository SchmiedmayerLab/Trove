#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Reject missing, failed or unexpectedly skipped Build and Test jobs."""

from enum import StrEnum
import json
import sys


class Result(StrEnum):
    SUCCESS = "success"
    FAILURE = "failure"
    CANCELLED = "cancelled"
    SKIPPED = "skipped"


COMPONENTS = {
    "api": "api",
    "server": "server",
    "web": "web",
    "ios": "ios",
    "ios_ui": "ios-ui",
    "infrastructure": "infrastructure",
}
SELECTORS = {*COMPONENTS, "devstack"}
JOBS = {"changes", *COMPONENTS.values(), "dev-stack", "native-line-coverage", "coverage", "secret-scan", "vulnerability-scan"}


def object_fields(value: object, label: str) -> dict[str, object]:
    if not isinstance(value, dict) or any(not isinstance(key, str) for key in value):
        raise ValueError(f"{label} must be an object with string keys")
    return dict(value)


def verify(value: object) -> list[str]:
    jobs = object_fields(value, "Job results")
    if jobs.keys() != JOBS:
        raise ValueError("Job inventory does not match the Build and Test gate")
    results: dict[str, Result] = {}
    for name in sorted(JOBS):
        raw = object_fields(jobs[name], name).get("result")
        if not isinstance(raw, str):
            raise ValueError(f"{name}: missing or invalid result")
        try:
            results[name] = Result(raw)
        except ValueError as error:
            raise ValueError(f"{name}: unsupported result") from error

    if results["changes"] != Result.SUCCESS:
        raise ValueError("Component detection did not succeed")
    outputs = object_fields(object_fields(jobs["changes"], "changes").get("outputs"), "Selectors")
    if outputs.keys() != SELECTORS:
        raise ValueError("Selector inventory does not match the Build and Test gate")
    selected: dict[str, bool] = {}
    for name in sorted(SELECTORS):
        raw = outputs[name]
        if not isinstance(raw, str) or raw not in ("true", "false"):
            raise ValueError(f"{name}: selector must be the string true or false")
        selected[name] = raw == "true"

    required = {"changes", "secret-scan", "vulnerability-scan", *(job for selector, job in COMPONENTS.items() if selected[selector])}
    if any(selected[name] for name in ("server", "web", "infrastructure", "devstack")):
        required.add("dev-stack")
    if selected["ios"] or selected["ios_ui"]:
        required.add("native-line-coverage")
    if required & {"api", "server", "web", "ios", "ios-ui", "dev-stack"}:
        required.add("coverage")

    for name, result in results.items():
        if result in (Result.FAILURE, Result.CANCELLED):
            raise ValueError(f"{name}: {result.value}")
        if name in required and result != Result.SUCCESS:
            raise ValueError(f"{name}: selected job did not succeed ({result.value})")
    return sorted(required)


def main() -> int:
    try:
        required = verify(json.load(sys.stdin))
    except (ValueError, TypeError) as error:
        print(f"CI verification failed: {error}", file=sys.stderr)
        return 1
    print("Required jobs passed: " + ", ".join(required))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
