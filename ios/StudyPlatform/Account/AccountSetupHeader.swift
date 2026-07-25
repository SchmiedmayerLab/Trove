//
// This source file is part of the StudyPlatform-iOS open source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

@_spi(TestingSupport)
import SpeziAccount
import SwiftUI


struct AccountSetupHeader: View {
    @Environment(Account.self) private var account
    @Environment(\.accountSetupState) private var setupState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "stethoscope.circle.fill")
                .resizable()
                .frame(width: 88, height: 88)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("StudyPlatform")
                .font(.largeTitle.bold())
            if account.signedIn, case .presentingExistingAccount = setupState {
                Text("You are signed in. Complete the remaining details to participate in studies.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                Text("Sign in with your account to browse and join research studies.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 32)
        .padding(.horizontal)
    }
}
