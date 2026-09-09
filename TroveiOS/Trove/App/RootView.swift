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
    @Environment(TroveAPIModule.self) private var api
    @Environment(EnrollmentModel.self) private var enrollments
    @Environment(BrowseModel.self) private var studies
    @Environment(ConsentModel.self) private var consents

    var body: some View {
        Group {
            if isAccountSetupComplete {
                TabView {
                    Tab("Studies", systemImage: "list.bullet.rectangle") {
                        BrowseView()
                    }
                    Tab("Health Data", systemImage: "heart.text.square") {
                        HealthDataView()
                    }
                }
                .id(api.sessionSnapshot)
            } else {
                OnboardingView()
            }
        }
        .onChange(of: api.sessionSnapshot) {
            ErrorHandler.shared.currentError = nil
            enrollments.synchronizeSession()
            studies.synchronizeSession()
            consents.synchronizeSession()
        }
        .environment(ErrorHandler.shared)
        .handlesErrors()
    }

    private var isAccountSetupComplete: Bool {
        guard let account, account.signedIn, let details = account.details,
              let session = api.sessionSnapshot, session.subject == details.accountId else {
            return false
        }
        return !details.isIncomplete && details.hasRequiredProfileFields
    }
}
