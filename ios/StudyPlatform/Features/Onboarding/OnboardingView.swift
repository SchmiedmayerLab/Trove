//
// This source file is part of the StudyPlatform-iOS open source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import SpeziAccount
import SwiftUI

/// Welcome screen shown when no participant is signed in. Hosts SpeziAccount's `AccountSetup`
/// view which composes the registered identity providers (i.e. the Keycloak sign-in button) and
/// transparently triggers the follow-up info sheet for any required profile fields.
struct OnboardingView: View {
    var body: some View {
        NavigationStack {
            AccountSetup { _ in
                // RootView reacts to account.signedIn flipping.
            } header: {
                AccountSetupHeader()
            }
        }
    }
}
