//
// This source file is part of the StudyPlatform-iOS open source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Static configuration of a Keycloak realm consumed by ``KeycloakAccountService``.
///
/// Provided by the embedding application at module construction time.
public struct KeycloakConfiguration: Sendable {
    /// The Keycloak realm issuer URL, e.g. `https://keycloak.example.com/realms/study-platform`.
    public let issuer: URL
    /// The Keycloak client identifier registered for this application.
    public let clientID: String
    /// The redirect URI registered with the Keycloak client. Must match an entry in `CFBundleURLTypes`.
    public let redirectURI: URL

    public init(issuer: URL, clientID: String, redirectURI: URL) {
        self.issuer = issuer
        self.clientID = clientID
        self.redirectURI = redirectURI
    }
}
