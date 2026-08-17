//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import SwiftUI


/// Full-bleed error state used to replace empty content. Includes a retry button when supplied.
struct ProblemUnavailableView: View {
    let title: LocalizedStringResource
    let error: any Error
    var retry: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.localizedDescription)
        } actions: {
            if let retry {
                Button("Retry", action: retry)
            }
        }
    }
}
