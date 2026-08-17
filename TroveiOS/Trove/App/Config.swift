//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


enum Config {
    #if DEBUG
    private static let environment = Environment.development
    #else
    private static let environment = Environment.production
    #endif

    static var apiBaseURL: URL { environment.apiBaseURL }
    static var keycloakIssuer: URL { environment.keycloakIssuer }
    static var keycloakClientID: String { environment.keycloakClientID }
    static var keycloakRedirectScheme: String { environment.keycloakRedirectScheme }
    static var keycloakRedirectURI: URL {
        guard let url = URL(string: "\(keycloakRedirectScheme)://callback") else {
            preconditionFailure("The redirect scheme does not form a valid URL")
        }
        return url
    }
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
