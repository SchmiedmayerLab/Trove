//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import SQLKit


/// Installation credentials prove possession only; verified participant authentication is always required separately.
struct SourceInstallationCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let key: SymmetricKey

    var description: String { "SourceInstallationCredential(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

    init(base64: String) throws {
        guard base64.utf8.count == 44, let bytes = Data(base64Encoded: base64), bytes.count == 32,
              bytes.base64EncodedString() == base64 else { throw ServerError.badRequest("Invalid installation credential") }
        key = SymmetricKey(data: bytes)
    }

    private static func message(_ participantID: UUID, _ sourceID: UUID, _ registrationID: UUID) -> Data {
        Data("trove.source-installation.v1:\(participantID.uuidString.lowercased()):\(sourceID.uuidString.lowercased()):\(registrationID.uuidString.lowercased())".utf8)
    }

    func verifier(participantID: UUID, sourceID: UUID, registrationID: UUID) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Self.message(participantID, sourceID, registrationID), using: key))
    }

    func verifies(_ installation: SourceInstallation) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            installation.credentialVerifier,
            authenticating: Self.message(installation.participantID, installation.sourceID, installation.registrationID),
            using: key
        )
    }
}


/// Immutable installation identity with one-way revocation. No private derivation key is stored here.
struct SourceInstallation: Sendable, Equatable {
    let participantID: UUID
    let sourceID: UUID
    let registrationID: UUID
    let credentialVerifier: Data
    let createdAt: Date
    let revokedAt: Date?

    init(row: any SQLRow) throws {
        participantID = try row.decode(column: "participant_id", as: UUID.self)
        sourceID = try row.decode(column: "source_id", as: UUID.self)
        registrationID = try row.decode(column: "registration_id", as: UUID.self)
        credentialVerifier = try row.decode(column: "credential_verifier", as: Data.self)
        createdAt = try row.decode(column: "created_at", as: Date.self)
        revokedAt = try row.decode(column: "revoked_at", as: Date?.self)
        guard credentialVerifier.count == 32, revokedAt.map({ $0 >= createdAt }) ?? true else {
            throw ServerError.internalServerError("Invalid retained installation state")
        }
    }
}
