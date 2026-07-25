//
// This source file is part of the StudyPlatform-iOS open source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziAccount
import SwiftUI


extension AccountKeyCategory {
    public static let profile = Self(title: "Profile")
}


extension AccountDetails {
    @AccountKey(id: "region", name: "Region", category: .profile, options: .default, as: String.self)
    public var region: String?

    @AccountKey(id: "language", name: "Language", category: .profile, options: .default, as: String.self)
    public var language: String?

    @AccountKey(id: "phoneNumber", name: "Phone Number", category: .contactDetails, options: .default, as: String.self)
    public var phoneNumber: String?

    /// Read-only marker key whose ``KeycloakConsoleDisplay`` opens the user's Keycloak self-service console.
    @AccountKey(
        id: "keycloakAccountConsole",
        name: "Manage Sign-In & Security",
        category: .credentials,
        options: .display,
        as: String.self,
        displayView: KeycloakConsoleDisplay.self
    )
    public var keycloakAccountConsole: String?
}


@KeyEntry(\.region, \.language, \.phoneNumber, \.keycloakAccountConsole)
extension AccountKeys {}


extension AccountDetails {
    /// App-level policy: profile is "complete" once all server-required fields are populated.
    var hasRequiredProfileFields: Bool {
        name != nil
            && genderIdentity != nil
            && dateOfBirth != nil
            && region != nil
            && language != nil
            && phoneNumber != nil
    }
}
