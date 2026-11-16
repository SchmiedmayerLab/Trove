#!/usr/bin/env bash
#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT
#
set -euo pipefail
actual="$(xcodebuild -version)"
printf '%s\n' "$actual"
if [[ "$actual" != $'Xcode 27.2\nBuild version 27B52' ]]; then
  echo 'Verification requires stable Xcode 27.2 (27B52).' >&2
  exit 1
fi
