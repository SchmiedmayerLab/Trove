//
// This source file is part of the StudyPlatform-iOS open source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
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
        .accessibilityIdentifier("StudyPlatform:YourAccount")
    }
}
