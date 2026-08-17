//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveAccount
import SwiftUI


struct AccountSheet: View {
    private let dismissAfterSignIn: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(Account.self) private var account

    @State private var isInSetup = false

    var body: some View {
        NavigationStack {
            if account.signedIn && !isInSetup {
                AccountOverview(close: .showCloseButton)
            } else {
                AccountSetup { _ in
                    if dismissAfterSignIn {
                        dismiss()
                    }
                } header: {
                    AccountSetupHeader()
                }
                .onAppear { isInSetup = true }
            }
        }
    }

    init(dismissAfterSignIn: Bool = true) {
        self.dismissAfterSignIn = dismissAfterSignIn
    }
}
