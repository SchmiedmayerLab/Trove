//
// This source file is part of the StudyPlatform-iOS open source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import SpeziAccount
import SpeziViews
import SwiftUI


/// Sign-in / sign-up buttons that delegate into ``KeycloakAccountService``.
///
/// Inserted into ``AccountSetup``'s primary section by ``KeycloakAccountService`` via ``IdentityProvider``.
public struct KeycloakSignInView: View {
    @Environment(KeycloakAccountService.self) private var service

    @State private var signInState: ViewState = .idle
    @State private var signUpState: ViewState = .idle

    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            AccountServiceButton(
                "Sign in with Keycloak",
                systemImage: "person.badge.key",
                state: $signInState
            ) {
                try await service.signIn()
            }
            AccountServiceButton(
                "Create Account",
                systemImage: "person.crop.circle.badge.plus",
                state: $signUpState
            ) {
                try await service.signUp()
            }
        }
    }
}
