//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import SwiftUI


struct HealthDataExplanationView: View {
    var body: some View {
        Section {
            Text(
                "Only data covered by your study consents is shared. One sample can support more than one study without being uploaded twice."
            )
            Text(
                "Health does not tell apps whether read access was denied. An empty sync does not confirm permission or complete data delivery."
            )
            Text(
                """
                After device setup and Health access review, collection can resume when Health notifies this app. \
                Open the app to continue pending uploads. Background updates depend on the system and are not guaranteed.
                """
            )
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
