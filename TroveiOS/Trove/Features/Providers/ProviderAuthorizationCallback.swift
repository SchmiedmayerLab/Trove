//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Validates the callback location before returning bounded authorization evidence.
/// The server separately verifies the one-time state and exchanges the code.
struct ProviderAuthorizationCallback: Equatable {
    enum Failure: Error { case invalidRedirect, invalidCallback, authorizationDeclined }

    let state: String
    let code: String

    init(url: URL, redirect: URL) throws {
        let expected = try Self.redirectComponents(redirect)
        guard url.absoluteString.utf8.count <= 8_192,
              let actual = URLComponents(url: url, resolvingAgainstBaseURL: false),
              actual.scheme == expected.scheme, actual.host == expected.host,
              (actual.port ?? 443) == (expected.port ?? 443), actual.percentEncodedPath == expected.percentEncodedPath,
              actual.user == nil, actual.password == nil, actual.fragment == nil else {
            throw Failure.invalidCallback
        }
        let items = actual.queryItems ?? []
        guard !items.contains(where: { $0.name == "error" }) else { throw Failure.authorizationDeclined }
        let states = items.filter { $0.name == "state" }
        let codes = items.filter { $0.name == "code" }
        guard states.count == 1, codes.count == 1,
              let state = states.first?.value, (32...128).contains(state.utf8.count),
              state.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let code = codes.first?.value, (1...4_096).contains(code.utf8.count),
              !code.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.invalidCallback
        }
        self.state = state
        self.code = code
    }

    static func redirectComponents(_ redirect: URL) throws -> URLComponents {
        guard let value = URLComponents(url: redirect, resolvingAgainstBaseURL: false),
              value.scheme == "https", let host = value.host, !host.isEmpty,
              value.user == nil, value.password == nil, value.query == nil, value.fragment == nil,
              value.port == nil || value.port == 443, !value.path.isEmpty else {
            throw Failure.invalidRedirect
        }
        return value
    }
}
