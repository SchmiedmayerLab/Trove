//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIClient
import TroveAPITypes


enum Config {
    #if DEBUG
    private static let environment = Environment.development
    #else
    private static let environment = Environment.production
    #endif

    static var apiBaseURL: URL {
        #if DEBUG
        endpointOverride(named: "TROVE_API_BASE_URL") ?? environment.apiBaseURL
        #else
        environment.apiBaseURL
        #endif
    }
    static var keycloakIssuer: URL {
        #if DEBUG
        endpointOverride(named: "TROVE_KEYCLOAK_ISSUER") ?? environment.keycloakIssuer
        #else
        environment.keycloakIssuer
        #endif
    }
    /// An operator-approved HTTPS callback requires the matching Associated Domains entitlement.
    static var providerRedirectURI: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "TroveProviderRedirectURI") as? String,
              let url = URL(string: value), (try? ProviderAuthorizationCallback.redirectComponents(url)) != nil else {
            return nil
        }
        return url
    }

    static var keycloakClientID: String { environment.keycloakClientID }
    static var keycloakRedirectScheme: String { environment.keycloakRedirectScheme }
    static var keycloakRedirectURI: URL {
        guard let url = URL(string: "\(keycloakRedirectScheme)://callback") else {
            preconditionFailure("The redirect scheme does not form a valid URL")
        }
        return url
    }

    #if DEBUG
    private static func endpointOverride(named name: String) -> URL? {
        guard let value = ProcessInfo.processInfo.environment[name] else {
            return nil
        }
        guard let url = URL(string: value),
              let scheme = url.scheme,
              ["http", "https"].contains(scheme),
              url.host != nil else {
            preconditionFailure("Invalid endpoint override for \(name)")
        }
        return url
    }
    #endif
}

extension Config {
    fileprivate enum Environment {
        case development
        case production

        // These mirror TroveInfrastructure/apps/prod; keep them in step when the deployment moves.
        var apiBaseURL: URL {
            switch self {
            case .development: Self.endpoint("http://localhost:8080/api/v0")
            case .production: Self.endpoint("https://console.troveplatform.org/api/v0")
            }
        }

        var keycloakIssuer: URL {
            switch self {
            case .development: Self.endpoint("http://localhost:8180/realms/trove")
            case .production: Self.endpoint("https://console.troveplatform.org/auth/realms/trove")
            }
        }

        var keycloakClientID: String { "trove-app" }
        var keycloakRedirectScheme: String { "trove" }

        /// The endpoints above are compile-time constants, so a failure here is a build mistake.
        private static func endpoint(_ string: String) -> URL {
            guard let url = URL(string: string) else {
                preconditionFailure("Not a valid built-in endpoint: \(string)")
            }
            return url
        }
    }
}


extension Config {
    /// Signed application configuration; debug launch overrides exercise bounded-capacity behavior.
    static func collectionCapacity() throws -> EventDeliveryCapacityConfiguration {
        let key = "TroveCollectionCapacity"
        var values: [String: String] = [:]
        if let configured = Bundle.main.object(forInfoDictionaryKey: key) {
            guard let settings = configured as? [String: String] else { throw DeliveryJournalError.invalidConfiguration }
            values = settings
        }
        #if DEBUG
        for setting in CollectionCapacitySetting.allCases {
            if let value = ProcessInfo.processInfo.environment[setting.rawValue] { values[setting.rawValue] = value }
        }
        #endif
        return try EventDeliveryCapacityConfiguration(settings: values)
    }
}
