//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Vapor


enum AppEnvironment: String, Sendable, CaseIterable {
    case development
    case production
}


extension Environment {
    enum Database {
        static var host: String { Environment.require("DATABASE_HOST") }
        static var port: Int { Environment.requireInt("DATABASE_PORT") }
        static var username: String { Environment.require("DATABASE_USERNAME") }
        static var password: String { Environment.require("DATABASE_PASSWORD") }
        static var name: String { Environment.require("DATABASE_NAME") }
    }

    enum Keycloak {
        static var issuer: String { Environment.require("KEYCLOAK_ISSUER") }
        static var apiAudience: String { Environment.require("KEYCLOAK_API_AUDIENCE") }
        static var url: String { Environment.require("KEYCLOAK_URL") }
        static var realm: String { Environment.require("KEYCLOAK_REALM") }
        static var clientId: String { Environment.require("KEYCLOAK_CLIENT_ID") }
        static var clientSecret: String { Environment.require("KEYCLOAK_CLIENT_SECRET") }
        static var researcherRole: String { Environment.require("KEYCLOAK_RESEARCHER_ROLE") }
        static var participantRole: String { Environment.require("KEYCLOAK_PARTICIPANT_ROLE") }
    }

    enum ObjectStore {
        static var endpoint: String { Environment.require("S3_ENDPOINT") }
        static var accessKey: String { Environment.require("S3_ACCESS_KEY") }
        static var secretKey: String { Environment.require("S3_SECRET_KEY") }
        static var bucket: String { Environment.require("S3_BUCKET") }
        static var region: String { Environment.require("S3_REGION") }
    }

    static var appEnvironment: AppEnvironment {
        let raw = Environment.require("APP_ENVIRONMENT")
        guard let value = AppEnvironment(rawValue: raw) else {
            fatalError("Invalid APP_ENVIRONMENT '\(raw)'. Expected one of: \(AppEnvironment.allCases.map(\.rawValue))")
        }
        return value
    }

    fileprivate static func require(_ key: String) -> String {
        guard let value = Environment.get(key) else {
            fatalError("Missing required environment variable: \(key)")
        }
        return value
    }

    fileprivate static func requireInt(_ key: String) -> Int {
        let raw = require(key)
        guard let value = Int(raw) else {
            fatalError("Environment variable \(key) must be an integer, got: \(raw)")
        }
        return value
    }
}
