#!/bin/bash
# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: bash TroveiOS/scripts/capture-documentation.sh SIMULATOR_UDID studies|study|consent|health-data" >&2
    exit 2
fi
udid="$1"
name="$2"
case "$name" in
    studies|study) expected='Daily Activity Study' ;;
    consent) expected='About this study' ;;
    health-data) expected='Heart Rate' ;;
    *) echo "Unknown documentation capture: $name" >&2; exit 2 ;;
esac
root="$(cd "$(dirname "$0")/../.." && pwd)"
rocketsim="${ROCKETSIM_CLI:-/Applications/RocketSim.app/Contents/Resources/CLI/rocketsim}"
[ -x "$rocketsim" ] || { echo "Install RocketSim with its CLI first." >&2; exit 1; }
output="$root/docs/images/mobile"
mkdir -p "$output"
temporary="$(mktemp -d)"
trap 'rm -f "$temporary/light.png" "$temporary/dark.png"; rmdir "$temporary"' EXIT

# Use only the dedicated synthetic-data simulator from the capture guide.
# No navigation occurs here. Run only after automated tests have released the simulator.
"$rocketsim" preview --udid "$udid" --label 'Trove Documentation'
"$rocketsim" wait element --udid "$udid" --label "$expected" --timeout 2
xcrun simctl status_bar "$udid" override --time '9:41' --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
for appearance in light dark; do
    xcrun simctl ui "$udid" appearance "$appearance"
    "$rocketsim" wait time --ms 800
    "$rocketsim" wait element --udid "$udid" --label "$expected" --timeout 2
    "$rocketsim" screenshot --udid "$udid" --bezel device --background transparent > "$temporary/$appearance.png"
    # Decode before replacing a reviewed image; an error envelope is not a PNG.
    sips --getProperty pixelWidth --getProperty pixelHeight "$temporary/$appearance.png"
done
mv "$temporary/light.png" "$output/$name.png"
mv "$temporary/dark.png" "$output/$name~dark.png"
xcrun simctl ui "$udid" appearance light
echo "Review both images before committing: $output/$name.png"
