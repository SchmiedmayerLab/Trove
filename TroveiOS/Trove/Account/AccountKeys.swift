//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveAccount
import SwiftUI


extension AccountKeyCategory {
    /// Groups the account keys a participant edits about themselves.
    public static let profile = Self(title: "Profile")
}


// swiftlint:disable attributes - @AccountKey argument lists do not fit on the declaration line
extension AccountDetails {
    /// The participant's region, used to localise study content.
    @AccountKey(id: "region", name: "Region", category: .profile, options: .default, as: String.self)
    public var region: String?

    /// The participant's preferred language.
    @AccountKey(id: "language", name: "Language", category: .profile, options: .default, as: String.self)
    public var language: String?

    /// The participant's phone number.
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
// swiftlint:enable attributes


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
