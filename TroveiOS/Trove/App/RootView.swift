//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveAccount
import SwiftUI


/// Root navigation gate: signed out → onboarding; signed in with complete profile → tab UI.
/// Stays on onboarding until AccountSetup finishes collecting all required server-side profile fields.
struct RootView: View {
    @Environment(Account.self) private var account: Account?

    var body: some View {
        Group {
            if isAccountSetupComplete {
                TabView {
                    Tab("Studies", systemImage: "list.bullet.rectangle") {
                        BrowseView()
                    }
                }
            } else {
                OnboardingView()
            }
        }
        .environment(ErrorHandler.shared)
        .handlesErrors()
    }

    private var isAccountSetupComplete: Bool {
        guard let account, account.signedIn, let details = account.details else {
            return false
        }
        return !details.isIncomplete && details.hasRequiredProfileFields
    }
}
