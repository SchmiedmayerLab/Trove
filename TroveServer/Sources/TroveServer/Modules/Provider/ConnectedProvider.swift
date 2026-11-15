//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveProviderFHIR
import GroveFHIRContract


enum ConnectedProvider: String, Codable, CaseIterable, Sendable {
    case withings
    case oura
    case googleHealthAPI = "google-health-api"

    var converter: ProviderCapabilities.Provider {
        switch self {
        case .withings: .withings
        case .oura: .oura
        case .googleHealthAPI: .googleHealthAPI
        }
    }

    var repositoryKind: SourceRepositoryKind {
        switch self {
        case .withings: .withings
        case .oura: .oura
        case .googleHealthAPI: .googleHealthAPI
        }
    }

    var authorizationURL: URL {
        switch self {
        case .withings: URL(string: "https://account.withings.com/oauth2_user/authorize2")!
        case .oura: URL(string: "https://cloud.ouraring.com/oauth/authorize")!
        case .googleHealthAPI: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        }
    }

    var tokenURL: URL {
        switch self {
        case .withings: URL(string: "https://wbsapi.withings.net/v2/oauth2")!
        case .oura: URL(string: "https://api.ouraring.com/oauth/token")!
        case .googleHealthAPI: URL(string: "https://oauth2.googleapis.com/token")!
        }
    }
}
