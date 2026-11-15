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
    health-data) expected='HealthKit Data' ;;
    *) echo "Unknown documentation capture: $name" >&2; exit 2 ;;
esac
root="$(cd "$(dirname "$0")/../.." && pwd)"
rocketsim="${ROCKETSIM_CLI:-/Applications/RocketSim.app/Contents/Resources/CLI/rocketsim}"
[ -x "$rocketsim" ] || { echo "Install RocketSim with its CLI first." >&2; exit 1; }
output="$root/docs/images/mobile"
mkdir -p "$output"
# Every image uses the same device and runtime, so all captures share one frame and size.
device="$(xcrun simctl list devices --json | jq --raw-output --arg udid "$udid" '
    .devices | to_entries[] | .key as $runtime | .value[]
    | select(.udid == $udid) | "\($runtime) \(.deviceTypeIdentifier) \(.state)"')"
if [ "$device" != 'com.apple.CoreSimulator.SimRuntime.iOS-27-2 com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro Booted' ]; then
    echo "Use a booted iPhone 18 Pro Simulator with iOS 27.2 (found: ${device:-none})." >&2
    exit 1
fi
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
    # Pin the layout options instead of relying on saved RocketSim preferences.
    "$rocketsim" screenshot --udid "$udid" --bezel device --background transparent \
        --ratio auto --orientation portrait > "$temporary/$appearance.png"
    # Decode before replacing a reviewed image; an error envelope is not a PNG.
    size="$(sips --getProperty pixelWidth --getProperty pixelHeight "$temporary/$appearance.png" \
        | awk '/pixel(Width|Height)/ { printf "%s ", $2 }')"
    if [ "$size" != '1350 2760 ' ]; then
        echo "Expected a 1350 x 2760 framed $appearance capture (found: ${size:-no image})." >&2
        exit 1
    fi
done
mv "$temporary/light.png" "$output/$name.png"
mv "$temporary/dark.png" "$output/$name~dark.png"
xcrun simctl ui "$udid" appearance light
echo "Review both images before committing: $output/$name.png"
