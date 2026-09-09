//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import JWTKit


/// Trusted deployment configuration, never derived from token claims or headers.
struct KeycloakTokenPolicy: Sendable {
    let issuer: String
    let apiAudience: String
    let algorithm: String

    init(issuer: String, apiAudience: String, algorithm: String = "RS256") throws {
        guard let url = URL(string: issuer),
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(url.host)),
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              !apiAudience.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              apiAudience == apiAudience.trimmingCharacters(in: .whitespacesAndNewlines),
              ["RS256", "HS256"].contains(algorithm) else {
            throw ServerError.internalServerError("Invalid token verification configuration")
        }
        self.issuer = issuer
        self.apiAudience = apiAudience
        self.algorithm = algorithm
    }

    func verify(_ payload: KeycloakJWTPayload) throws {
        guard payload.iss.value == issuer,
              payload.aud.value.contains(apiAudience),
              !payload.sub.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServerError.invalidToken
        }
    }
}
