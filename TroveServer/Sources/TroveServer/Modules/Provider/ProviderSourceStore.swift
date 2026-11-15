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


enum ProviderSourceStore {
    /// The participant and registration are locked by the linking transaction before this call.
    static func create(
        participantID: UUID, registration: ProviderRegistration, actor: AuthContext,
        keyring: SourceIdentityKeyring, on database: any Database
    ) async throws -> SourceBinding {
        guard database.inTransaction else { throw AuditError.transactionRequired }
        let sql = try ProviderSQL.sql(database)
        let existing = try await sql.raw("""
            SELECT * FROM source_bindings WHERE participant_id = \(bind: participantID)
                AND repository_kind = \(bind: registration.provider.repositoryKind.rawValue) AND kind = 'server-worker'
            ORDER BY created_at, id LIMIT 2
            """).all()
        // Conflicting historical authorities require explicit reconciliation; never discard or replace their keys.
        guard existing.count <= 1 else { throw ProviderFailure.invalidConfiguration }
        if let row = existing.first {
            let source = try SourceBinding(row: row)
            guard source.revokedAt == nil else { throw ProviderFailure.fenced }
            _ = try await SourceIdentityKeyStore(keyring: keyring).recover(
                sourceID: source.id, participantID: participantID, on: database
            )
            return source
        }
        let id = UUID()
        let keyID = UUID()
        let root = actor.issuer + "/trove/sources/" + id.uuidString.lowercased()
        let namespaces = try SourceIdentityNamespaces.assign(root: root, keyID: keyID)
        try await sql.raw("""
            INSERT INTO source_bindings (
                id, participant_id, key_id, key_epoch, repository_kind, kind, provider_registration_id,
                identifier_root, event_identifier_system, participant_identifier_system, participant_identifier_value, created_at
            ) VALUES (
                \(bind: id), \(bind: participantID), \(bind: keyID), '1', \(bind: registration.provider.repositoryKind.rawValue),
                'server-worker', \(bind: registration.id), \(bind: root), \(bind: namespaces.recordVersion.rawValue),
                \(bind: actor.issuer + "/trove/participants"), \(bind: participantID.uuidString.lowercased()), \(bind: Date())
            )
            """).run()
        guard let row = try await sql.raw("SELECT * FROM source_bindings WHERE id = \(bind: id)").first() else {
            throw ProviderFailure.unavailable
        }
        let source = try SourceBinding(row: row)
        _ = try await SourceIdentityKeyStore(keyring: keyring).provision(context: source.keyContext, on: database)
        try await AuditRepository.recordMutation(.init(
            context: actor.auditContext, action: .sourceRegistered,
            scope: .participantSource(participantID: participantID, sourceBindingID: id), target: .init(id: id)
        ), on: database)
        return source
    }
}
