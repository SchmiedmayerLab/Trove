//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import GroveFHIRContract


/// Deployment encryption keys protect recoverable participant HMAC keys. Neither is a signing key.
/// Rewrapping changes only storage encryption; changing the participant key requires a separate identity-continuity protocol.
struct SourceIdentityKeyring: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    enum Failure: Error, Equatable {
        case invalidConfiguration
        case creationRefused
        case invalidContext
        case invalidIdentityKey
        case recoveryUnavailable
    }

    /// Stored with the ciphertext. This is not the participant's derivation-key identifier.
    struct Envelope: Sendable, Equatable {
        let version: Int
        let encryptionKeyID: String
        let sealedKey: Data
    }

    let currentKeyID: String
    private let keys: [String: SymmetricKey]

    var description: String { "SourceIdentityKeyring(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

    init(currentKeyID: String, keys: [String: SymmetricKey]) throws {
        guard (1...8).contains(keys.count), Self.validKeyID(currentKeyID), keys[currentKeyID] != nil,
              keys.allSatisfy({ Self.validKeyID($0.key) && $0.value.bitCount == 256 }) else {
            throw Failure.invalidConfiguration
        }
        self.currentKeyID = currentKeyID
        self.keys = keys
    }

    private static func validKeyID(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    func seal(_ identityKey: SymmetricKey, context: SourceIdentityKeyContext) throws -> Envelope {
        guard identityKey.bitCount == 256 else { throw Failure.invalidIdentityKey }
        guard let encryptionKey = keys[currentKeyID] else { throw Failure.invalidConfiguration }
        do {
            let sealed = try identityKey.withUnsafeBytes { bytes in
                try AES.GCM.seal(Data(bytes), using: encryptionKey, authenticating: context.authenticatedData(encryptionKeyID: currentKeyID))
            }
            guard let combined = sealed.combined, combined.count == 60 else { throw Failure.recoveryUnavailable }
            return Envelope(version: 1, encryptionKeyID: currentKeyID, sealedKey: combined)
        } catch {
            throw Failure.recoveryUnavailable
        }
    }

    /// Missing historical keys, malformed envelopes and mismatched authority metadata never mint a replacement key.
    func open(_ envelope: Envelope, context: SourceIdentityKeyContext) throws -> SymmetricKey {
        guard envelope.version == 1, envelope.sealedKey.count == 60, let encryptionKey = keys[envelope.encryptionKeyID] else {
            throw Failure.recoveryUnavailable
        }
        do {
            let bytes = try AES.GCM.open(
                AES.GCM.SealedBox(combined: envelope.sealedKey),
                using: encryptionKey,
                authenticating: context.authenticatedData(encryptionKeyID: envelope.encryptionKeyID)
            )
            guard bytes.count == 32 else { throw Failure.recoveryUnavailable }
            return SymmetricKey(data: bytes)
        } catch {
            throw Failure.recoveryUnavailable
        }
    }

    /// Always authenticate before deciding that an envelope already uses the current encryption key.
    func rewrap(_ envelope: Envelope, context: SourceIdentityKeyContext) throws -> Envelope {
        let identityKey = try open(envelope, context: context)
        return envelope.encryptionKeyID == currentKeyID ? envelope : try seal(identityKey, context: context)
    }
}
