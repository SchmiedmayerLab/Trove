//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import Testing
@testable import TroveServer


struct ProviderCredentialVaultTests {
    @Test(arguments: ["participant", "registration", "record", "version", "purpose", "key"])
    func transplantingAnEnvelopeCannotChangeItsAuthority(field: String) throws {
        let key = SymmetricKey(size: .bits256)
        let vault = try ProviderCredentialVault(currentKeyID: "first", keys: ["first": key, "alias": key])
        let context = ProviderCredentialVault.Context(
            participantID: UUID(), registrationID: UUID(), recordID: UUID(), version: 1, purpose: .participantCredential
        )
        let bytes = Data("synthetic-credential-payload".utf8)
        let envelope = try vault.seal(bytes, context: context)
        let changed = ProviderCredentialVault.Context(
            participantID: field == "participant" ? UUID() : context.participantID,
            registrationID: field == "registration" ? UUID() : context.registrationID,
            recordID: field == "record" ? UUID() : context.recordID,
            version: field == "version" ? 2 : 1,
            purpose: field == "purpose" ? .accountIdentity : .participantCredential
        )
        let candidate = ProviderCredentialVault.Envelope(keyID: field == "key" ? "alias" : envelope.keyID, ciphertext: envelope.ciphertext)
        #expect(throws: ProviderFailure.unavailable) { try vault.open(candidate, context: changed) }
        #expect(try vault.open(envelope, context: context) == bytes)
    }

    @Test
    func rotationAndDiagnosticsKeepCredentialsConfidential() throws {
        let oldKey = SymmetricKey(size: .bits256), newKey = SymmetricKey(size: .bits256)
        let first = try ProviderCredentialVault(currentKeyID: "old", keys: ["old": oldKey])
        let rotated = try ProviderCredentialVault(currentKeyID: "new", keys: ["old": oldKey, "new": newKey])
        let current = try ProviderCredentialVault(currentKeyID: "new", keys: ["new": newKey])
        let context = ProviderCredentialVault.Context(
            participantID: UUID(), registrationID: UUID(), recordID: UUID(), version: 1, purpose: .participantCredential
        )
        let bytes = Data("synthetic-credential-payload".utf8)
        let old = try first.seal(bytes, context: context)
        let new = try rotated.seal(rotated.open(old, context: context), context: context)
        #expect(new.keyID == "new")
        #expect(try current.open(new, context: context) == bytes)
        #expect(throws: ProviderFailure.unavailable) { try current.open(old, context: context) }
        #expect(!old.ciphertext.contains(bytes))
        #expect(Mirror(reflecting: rotated).children.isEmpty)
        #expect(String(reflecting: rotated) == "ProviderCredentialVault(redacted)")
        let credentials = ProviderCredentials(
            accessToken: "synthetic-access",
            refreshToken: "synthetic-refresh",
            expiresAt: Date().addingTimeInterval(600),
            scopes: ["user.metrics"],
            accountID: "123"
        )
        #expect(String(reflecting: credentials) == "ProviderCredentials(redacted)")
        #expect(Mirror(reflecting: credentials).children.isEmpty)
    }
}
