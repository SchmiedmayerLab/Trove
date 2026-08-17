//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import SwiftUI


struct AccountButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button("Your Account", systemImage: "person.crop.circle") {
            isPresented = true
        }
        .accessibilityIdentifier("Trove:YourAccount")
    }
}
