<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# iOS

The participant-facing app. It fetches the study definitions authored in the web portal and renders them as informational screens, questionnaires, and HealthKit data-collection flows, using the generated `TroveAPIClient` from [`TroveAPI/`](../TroveAPI) and the Grove UI and data modules.

## Getting started

Open `Trove.xcodeproj` in Xcode and run the `Trove` scheme. The Swift package dependencies resolve on the first build.
