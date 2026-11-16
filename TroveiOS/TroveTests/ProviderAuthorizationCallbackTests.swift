//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import Trove


struct ProviderAuthorizationCallbackTests {
    private let redirect = URL(string: "https://app.example.org/provider/callback")!
    private let state = String(repeating: "a", count: 43)

    @Test
    func preservesDecodedCodeAndStateAtExactApprovedLocation() throws {
        let url = try #require(URL(string: "https://app.example.org/provider/callback?state=\(state)&code=a%2Bb%2Fc%3D"))
        let value = try ProviderAuthorizationCallback(url: url, redirect: redirect)
        #expect(value.code == "a+b/c=")
        #expect(value.state == state)
    }

    @Test(arguments: [
        "http://app.example.org/provider/callback", "https://other.example.org/provider/callback",
        "https://app.example.org/provider/callback/extra", "https://app.example.org:8443/provider/callback",
        "https://user@app.example.org/provider/callback", "https://app.example.org/provider/%63allback"
    ])
    func refusesDifferentCallbackLocations(location: String) throws {
        let url = try #require(URL(string: "\(location)?state=\(state)&code=code"))
        #expect(throws: ProviderAuthorizationCallback.Failure.invalidCallback) {
            try ProviderAuthorizationCallback(url: url, redirect: redirect)
        }
    }

    @Test(arguments: [
        "state=short&code=code", "state=STATE&code=one&code=two", "state=STATE&state=STATE&code=code",
        "state=STATE&code=", "state=STATE&code=%0A", "state=STATE&code=code#fragment"
    ])
    func refusesAmbiguousOrIncompleteEvidence(query: String) throws {
        let query = query.replacingOccurrences(of: "STATE", with: state)
        let url = try #require(URL(string: "https://app.example.org/provider/callback?\(query)"))
        #expect(throws: ProviderAuthorizationCallback.Failure.invalidCallback) {
            try ProviderAuthorizationCallback(url: url, redirect: redirect)
        }
    }

    @Test
    func refusalDoesNotReturnAuthorizationEvidence() throws {
        let url = try #require(URL(string: "https://app.example.org/provider/callback?state=\(state)&error=access_denied"))
        #expect(throws: ProviderAuthorizationCallback.Failure.authorizationDeclined) {
            try ProviderAuthorizationCallback(url: url, redirect: redirect)
        }
    }

    @Test
    func refusesOversizedCode() throws {
        let url = try #require(URL(string: "https://app.example.org/provider/callback?state=\(state)&code=\(String(repeating: "a", count: 4_097))"))
        #expect(throws: ProviderAuthorizationCallback.Failure.invalidCallback) {
            try ProviderAuthorizationCallback(url: url, redirect: redirect)
        }
    }
}
