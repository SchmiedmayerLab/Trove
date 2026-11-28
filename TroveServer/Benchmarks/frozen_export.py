# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT
"""Measure one frozen export through the CLI against a local synthetic study."""
import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
import time
import uuid


def verify_download(stream, manifest, members):
    """Verify the ordered member index against the downloaded bytes."""
    digest = hashlib.sha256()
    byte_count = 0
    if len(members) != manifest["recordCount"]:
        raise ValueError("Export record count differs from the index")
    for line_number, member in enumerate(members, start=1):
        line = stream.readline()
        if member["line"] != line_number or not line.endswith(b"\n"):
            raise ValueError("Export member order or line ending differs")
        record = line[:-1]
        if len(record) != member["byteCount"] or hashlib.sha256(record).hexdigest() != member["sha256"]:
            raise ValueError("Export member checksum or size differs")
        digest.update(line)
        byte_count += len(line)
    if stream.read(1) or byte_count != manifest["byteCount"] or digest.hexdigest() != manifest["sha256"]:
        raise ValueError("Export file differs from its manifest")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trove", default="trove")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--study", type=uuid.UUID, required=True)
    args = parser.parse_args()
    credential = sys.stdin.buffer.readline(65537)
    if not credential.strip() or len(credential) > 65536 or not 1 <= args.port <= 65535:
        parser.error("A local port and credential on standard input are required")
    options = ["--server", f"http://127.0.0.1:{args.port}/api/v0", "--allow-insecure-loopback",
               "--study", str(args.study), "--token-stdin"]
    elapsed = {}

    def measure(verb, *arguments, output=subprocess.PIPE):
        start = time.perf_counter()
        response = subprocess.run([args.trove, "export", verb, *options, *arguments], input=credential,
                                  stdout=output,
                                  stderr=subprocess.DEVNULL, check=False)
        elapsed[verb] = round(elapsed.get(verb, 0) + (time.perf_counter() - start) * 1000, 2)
        if response.returncode:
            sys.exit(f"Export {verb} failed with exit code {response.returncode}")
        if response.stdout is not None:
            return json.loads(response.stdout)

    job = measure("create", "--queue-only", "--request-id", str(uuid.uuid4()))
    job_id = str(uuid.UUID(job["id"]))
    manifest = measure("execute", job_id)
    if uuid.UUID(manifest["id"]) != uuid.UUID(job_id) or uuid.UUID(manifest["studyId"]) != args.study or manifest["status"] != "ready":
        raise ValueError("Export manifest does not match the requested study and job")
    members = []
    while True:
        page = measure("page", job_id, "--offset", str(len(members)), "--limit", "100")
        if uuid.UUID(page["exportId"]) != uuid.UUID(job_id):
            raise ValueError("Export page belongs to a different job")
        members.extend(page["members"])
        if page.get("nextOffset") is None:
            break
        if not page["members"] or page["nextOffset"] != len(members) or len(members) >= manifest["recordCount"]:
            raise ValueError("Export index pagination is inconsistent")
    with tempfile.TemporaryFile() as download:
        measure("download", job_id, output=download)
        download.seek(0)
        verify_download(download, manifest, members)
    print(json.dumps({"records": manifest["recordCount"], "bytes": manifest["byteCount"], "milliseconds": elapsed}))


if __name__ == "__main__":
    main()
