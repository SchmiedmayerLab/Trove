//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation


/// Dedicated deployment keys protect provider credentials; source-identity keys are independent.
struct ProviderCredentialVault: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    struct Envelope: Codable, Sendable, Equatable {
        let keyID: String
        let ciphertext: Data
    }

    struct Context: Sendable {
        enum Purpose: String, Sendable { case authorizationVerifier, participantCredential, accountIdentity }

        let participantID: UUID
        let registrationID: UUID
        let recordID: UUID
        let version: Int64
        let purpose: Purpose

        func authenticatedData(keyID: String) throws -> Data {
            guard version > 0 else { throw ProviderFailure.invalidConfiguration }
            return try JSONEncoder().encode([
                "trove-provider-secret-v1", purpose.rawValue, participantID.uuidString.lowercased(),
                registrationID.uuidString.lowercased(), recordID.uuidString.lowercased(), String(version), keyID
            ])
        }
    }

    let currentKeyID: String
    private let keys: [String: SymmetricKey]

    var description: String { "ProviderCredentialVault(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

    init(currentKeyID: String, keys: [String: SymmetricKey]) throws {
        guard (1...8).contains(keys.count), keys[currentKeyID] != nil,
              keys.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 64 && $0.value.bitCount == 256 }) else {
            throw ProviderFailure.invalidConfiguration
        }
        self.currentKeyID = currentKeyID
        self.keys = keys
    }

    func seal(_ bytes: Data, context: Context) throws -> Envelope {
        guard (1...65_536).contains(bytes.count), let key = keys[currentKeyID] else { throw ProviderFailure.invalidConfiguration }
        do {
            let box = try AES.GCM.seal(bytes, using: key, authenticating: context.authenticatedData(keyID: currentKeyID))
            guard let ciphertext = box.combined else { throw ProviderFailure.unavailable }
            return Envelope(keyID: currentKeyID, ciphertext: ciphertext)
        } catch { throw ProviderFailure.unavailable }
    }

    func open(_ envelope: Envelope, context: Context) throws -> Data {
        guard (29...65_564).contains(envelope.ciphertext.count), let key = keys[envelope.keyID] else { throw ProviderFailure.unavailable }
        do {
            return try AES.GCM.open(
                AES.GCM.SealedBox(combined: envelope.ciphertext),
                using: key,
                authenticating: context.authenticatedData(keyID: envelope.keyID)
            )
        } catch { throw ProviderFailure.unavailable }
    }
}
