//
// This source file is part of the StudyPlatform-iOS open source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import SpeziAccount
import SwiftUI


struct AccountSheet: View {
    private let dismissAfterSignIn: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(Account.self) private var account

    @State private var isInSetup = false

    init(dismissAfterSignIn: Bool = true) {
        self.dismissAfterSignIn = dismissAfterSignIn
    }

    var body: some View {
        NavigationStack {
            if account.signedIn && !isInSetup {
                AccountOverview(close: .showCloseButton)
            } else {
                AccountSetup { _ in
                    if dismissAfterSignIn { dismiss() }
                } header: {
                    AccountSetupHeader()
                }
                .onAppear { isInSetup = true }
            }
        }
    }
}
