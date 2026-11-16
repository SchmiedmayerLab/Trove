//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Not API content. Diagnostics and reflection must never reveal reusable credentials.
struct ProviderCredentials: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scopes: Set<String>
    let accountID: String

    var description: String { "ProviderCredentials(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

    func validate(requiredScopes: Set<String>, at instant: Date) throws {
        guard !accessToken.isEmpty, accessToken.utf8.count <= 16_384,
              !refreshToken.isEmpty, refreshToken.utf8.count <= 16_384,
              !accountID.isEmpty, accountID.utf8.count <= 512,
              expiresAt.timeIntervalSince1970.isFinite, expiresAt > instant,
              scopes.count <= 64, scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 255 }),
              requiredScopes.isSubset(of: scopes) else { throw ProviderFailure.scopeLost }
    }
}
