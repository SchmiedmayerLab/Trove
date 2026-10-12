//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Vapor


public struct KeycloakConfiguration: Sendable {
    public var issuer: String
    public var apiAudience: String
    public var url: String
    public var realm: String
    public var clientId: String
    public var clientSecret: String
    public var researcherRole: String
    public var participantRole: String
    var clientPolicy: KeycloakClientPolicy

    public var jwksURL: String {
        "\(url)/realms/\(realm)/protocol/openid-connect/certs"
    }

    var tokenPolicy: KeycloakTokenPolicy {
        get throws { try KeycloakTokenPolicy(issuer: issuer, apiAudience: apiAudience) }
    }

    public init() {
        self.issuer = Environment.Keycloak.issuer
        self.apiAudience = Environment.Keycloak.apiAudience
        self.url = Environment.Keycloak.url
        self.realm = Environment.Keycloak.realm
        self.clientId = Environment.Keycloak.clientId
        self.clientSecret = Environment.Keycloak.clientSecret
        self.researcherRole = Environment.Keycloak.researcherRole
        self.participantRole = Environment.Keycloak.participantRole
        self.clientPolicy = Environment.appEnvironment == .development ? .development : .production
    }

    /// Explicit configuration supports isolated deployments and tests without changing process state.
    init(
        issuer: String,
        apiAudience: String,
        url: String,
        realm: String,
        clientId: String,
        clientSecret: String,
        researcherRole: String,
        participantRole: String,
        clientPolicy: KeycloakClientPolicy = .production
    ) {
        self.issuer = issuer
        self.apiAudience = apiAudience
        self.url = url
        self.realm = realm
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.researcherRole = researcherRole
        self.participantRole = participantRole
        self.clientPolicy = clientPolicy
    }
}
