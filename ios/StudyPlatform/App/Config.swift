//
// This source file is part of the StudyPlatform-iOS open source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
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
    static var keycloakRedirectURI: URL { URL(string: "\(keycloakRedirectScheme)://callback")! }
}

private extension Config {
    enum Environment {
        case development
        case production

        var apiBaseURL: URL {
            switch self {
            case .development: URL(string: "http://localhost:8080/api/v0")!
            case .production:  URL(string: "https://api.example.com/api/v0")!
            }
        }

        var keycloakIssuer: URL {
            switch self {
            case .development: URL(string: "http://localhost:8180/realms/studyplatform")!
            case .production:  URL(string: "https://auth.example.com/realms/studyplatform")!
            }
        }

        var keycloakClientID: String { "studyplatform-app" }
        var keycloakRedirectScheme: String { "studyplatform" }
    }
}
