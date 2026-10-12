#!/usr/bin/env bash
# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

set -euo pipefail

# These toolchains are unused by the Linux image/real-store jobs. Never perform
# this cleanup on a developer machine or a persistent self-hosted runner.
if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_ENVIRONMENT:-}" != github-hosted || "${RUNNER_OS:-}" != Linux ]]; then
    echo "Disk preparation requires an ephemeral GitHub-hosted Linux runner." >&2
    exit 1
fi

df -h /
for directory in /usr/local/lib/android /usr/share/dotnet /opt/ghc /opt/hostedtoolcache/CodeQL; do
    if [[ -L "$directory" ]]; then
        echo "Refusing to remove a symlinked toolchain: $directory" >&2
        exit 1
    fi
    if [[ -d "$directory" ]]; then
        sudo rm -rf -- "$directory"
    fi
done

# Keep enough room for the cold Swift build, both images, scans and backing
# services. A successful S3 HTTP health check does not establish writable disk.
available_kib="$(df -Pk / | awk 'NR == 2 { print $4 }')"
if [[ ! "$available_kib" =~ ^[0-9]+$ ]] || (( available_kib < 30 * 1024 * 1024 )); then
    echo "The Linux verification job requires at least 30 GiB of free disk." >&2
    df -h /
    exit 1
fi
df -h /
