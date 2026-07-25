//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Vapor


public struct KeycloakConfiguration: Sendable {
    public var url: String
    public var realm: String
    public var clientId: String
    public var clientSecret: String
    public var researcherRole: String
    public var participantRole: String

    public var jwksURL: String {
        "\(url)/realms/\(realm)/protocol/openid-connect/certs"
    }

    public init() {
        self.url = Environment.Keycloak.url
        self.realm = Environment.Keycloak.realm
        self.clientId = Environment.Keycloak.clientId
        self.clientSecret = Environment.Keycloak.clientSecret
        self.researcherRole = Environment.Keycloak.researcherRole
        self.participantRole = Environment.Keycloak.participantRole
    }
}
