#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Export measured app source-line coverage from Xcode result archives, not function reports."""

import argparse
import json
import pathlib
import subprocess
import sys


SOURCE_ROOT = pathlib.PurePosixPath("TroveiOS/Trove")


def source_path(archived_path, repository):
    """Map a previous runner's absolute path to an existing app source in this checkout."""
    marker = f"/{SOURCE_ROOT}/"
    if archived_path.count(marker) != 1:
        return None
    suffix = archived_path.split(marker, 1)[1]
    parts = pathlib.PurePosixPath(suffix).parts
    if not parts or any(part in (".", "..") for part in parts) or "\n" in suffix or "\r" in suffix:
        raise ValueError("Invalid archived source path")
    relative = SOURCE_ROOT / suffix
    source = repository / relative
    if source.suffix != ".swift":
        return None
    if not source.resolve().is_relative_to(repository.resolve()) or not source.is_file():
        raise ValueError(f"Coverage source is absent from the checkout: {relative}")
    return relative.as_posix()


def line_counts(payload, archived_path):
    if not isinstance(payload, dict) or set(payload) != {archived_path}:
        raise ValueError("Unexpected Xcode archive file identity")
    rows = payload[archived_path]
    if not isinstance(rows, list):
        raise ValueError("Missing Xcode line-execution records")
    counts = {}
    seen = set()
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("Invalid Xcode line record")
        line = row.get("line")
        executable = row.get("isExecutable")
        if type(line) is not int or line <= 0 or line in seen or type(executable) is not bool:
            raise ValueError("Invalid or duplicate Xcode source line")
        seen.add(line)
        if executable:
            count = row.get("executionCount")
            if type(count) is not int or count < 0:
                raise ValueError("Executable line has no valid execution count")
            counts[line] = count
    return counts


def xccov(*arguments):
    return subprocess.run(
        ["xcrun", "xccov", "view", "--archive", *arguments],
        check=True, capture_output=True, text=True, timeout=60,
    ).stdout


def collect(bundles, repository):
    coverage = {}
    for bundle in bundles:
        measured_lines = 0
        paths = sorted(set(xccov("--file-list", str(bundle)).splitlines()))
        for archived_path in paths:
            relative = source_path(archived_path, repository)
            if relative is None:
                continue
            payload = json.loads(xccov("--file", archived_path, "--json", str(bundle)))
            counts = line_counts(payload, archived_path)
            measured_lines += len(counts)
            if not counts:
                continue
            merged = coverage.setdefault(relative, {})
            for line, count in counts.items():
                merged[line] = merged.get(line, 0) + count
        if measured_lines == 0:
            raise ValueError(f"No measured app source lines in result bundle: {bundle.name}")
    if not coverage:
        raise ValueError("No native coverage result bundles")
    return coverage


def lcov(coverage):
    records = []
    for source, counts in sorted(coverage.items()):
        records.append(f"SF:{source}")
        records.extend(f"DA:{line},{count}" for line, count in sorted(counts.items()))
        records.extend((f"LF:{len(counts)}", f"LH:{sum(count > 0 for count in counts.values())}", "end_of_record"))
    return "\n".join(records) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("bundles", type=pathlib.Path, nargs="+")
    args = parser.parse_args()
    if args.output.suffix != ".lcov":
        parser.error("The output must be an .lcov file")
    # Do not leave a previous passing report after a failed conversion.
    args.output.unlink(missing_ok=True)
    try:
        coverage = collect(args.bundles, args.repository)
        args.output.write_text(lcov(coverage), encoding="utf-8")
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Native line coverage failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
