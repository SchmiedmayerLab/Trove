//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import SQLKit


/// Installation possession is checked in addition to verified account/source ownership.
struct SourceInstallationProof: Sendable, CustomStringConvertible, CustomReflectable {
    let registrationID: UUID
    private let credential: SourceInstallationCredential

    var description: String { "SourceInstallationProof(redacted)" }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

    init(registrationID: UUID, credential: SourceInstallationCredential) {
        self.registrationID = registrationID
        self.credential = credential
    }

    init(registrationID: String, credentialBase64: String) throws {
        try self.init(registrationID: registrationID.requireId(), credential: SourceInstallationCredential(base64: credentialBase64))
    }

    /// Admission callers repeat this check after locking the participant, which serializes installation revocation.
    /// A read-only command replay may inspect retained registration without requiring active authority.
    func validate(source: SourceBinding, on database: any Database, requireActive: Bool = true) async throws -> SourceInstallation {
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        let row = try await sql.raw("""
            SELECT * FROM source_installations
            WHERE participant_id = \(bind: source.participantID) AND source_id = \(bind: source.id)
                AND registration_id = \(bind: registrationID)
            """)
            .first()
        guard let row else { throw ServerError.forbidden("Installation proof is not valid for this source") }
        let installation = try SourceInstallation(row: row)
        guard credential.verifies(installation) else { throw ServerError.forbidden("Installation proof is not valid for this source") }
        guard !requireActive || (source.revokedAt == nil && installation.revokedAt == nil) else {
            throw ServerError.conflict("Source installation is not active")
        }
        return installation
    }
}
