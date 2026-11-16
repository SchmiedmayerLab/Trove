//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Grove
import GroveFHIRContract
import SQLKit


/// Verified account ownership is independent of possession of an installation credential or identity key.
final class SourceInstallationService: Module, Sendable {
    struct Registration: Sendable, Equatable {
        let source: SourceBinding
        let installation: SourceInstallation
    }

    struct Recovery: Sendable {
        let registration: Registration
        let identity: SourceIdentityKeyStore.Recovered
    }

    let database: any Database
    let keyring: SourceIdentityKeyring

    init(database: any Database, keyring: SourceIdentityKeyring) {
        self.database = database
        self.keyring = keyring
    }

    func register(
        registrationID: UUID, repositoryKind: SourceRepositoryKind, credential: SourceInstallationCredential
    ) async throws -> Registration {
        let context = try AuthContext.checkIsParticipant()
        return try await database.transaction { transaction in
            let participantID = try await SourceBindingService.lockParticipant(context, on: transaction)
            let sql = try Self.sql(transaction)
            if let existing = try await Self.installation(registrationID, participantID: participantID, on: sql) {
                guard credential.verifies(existing) else { throw ServerError.forbidden }
                let source = try await Self.source(existing.sourceID, participantID: participantID, on: sql)
                guard source.repositoryKind == repositoryKind else { throw ServerError.conflict("Registration belongs to another repository") }
                // Retry returns retained state even after revocation; it cannot reactivate either authority.
                return Registration(source: source, installation: existing)
            }
            let source = try await self.logicalSource(repositoryKind, participantID: participantID, context: context, on: transaction)
            let verifier = credential.verifier(participantID: participantID, sourceID: source.id, registrationID: registrationID)
            try await sql.raw("""
                INSERT INTO source_installations (participant_id, source_id, registration_id, credential_verifier, created_at)
                VALUES (\(bind: participantID), \(bind: source.id), \(bind: registrationID), \(bind: verifier), \(bind: max(Date(), source.createdAt)))
                """)
                .run()
            try await Self.audit(.sourceInstallationRegistered, registrationID: registrationID, source: source, context: context, on: transaction)
            guard let installation = try await Self.installation(registrationID, participantID: participantID, on: sql) else {
                throw ServerError.internalServerError("Installation registration was not retained")
            }
            return Registration(source: source, installation: installation)
        }
    }

    func find(registrationID: UUID) async throws -> Registration {
        let context = try AuthContext.checkIsParticipant()
        let participant = try await ProfileRepository(database: database).findByIdentity(issuer: context.issuer, subject: context.subject)
        guard let participant else { throw ServerError.notFound("Source installation not found") }
        return try await Self.registration(registrationID, participantID: participant.requireID(), on: Self.sql(database))
    }

    func recover(registrationID: UUID, credential: SourceInstallationCredential) async throws -> Recovery {
        let context = try AuthContext.checkIsParticipant()
        return try await database.transaction { transaction in
            let participantID = try await SourceBindingService.lockParticipant(context, on: transaction)
            let registration = try await Self.registration(registrationID, participantID: participantID, on: Self.sql(transaction))
            guard credential.verifies(registration.installation) else { throw ServerError.forbidden }
            guard registration.installation.revokedAt == nil, registration.source.revokedAt == nil else {
                throw ServerError.conflict("Source installation is not active")
            }
            let identity = try await self.recoverKey(source: registration.source, on: transaction)
            try await Self.audit(
                .sourceIdentityDisclosure, registrationID: registrationID, source: registration.source, context: context, on: transaction
            )
            return Recovery(registration: registration, identity: identity)
        }
    }

    /// The verified owner can revoke a lost installation without possessing its credential.
    func revoke(registrationID: UUID) async throws -> Registration {
        let context = try AuthContext.checkIsParticipant()
        return try await database.transaction { transaction in
            let participantID = try await SourceBindingService.lockParticipant(context, on: transaction)
            let sql = try Self.sql(transaction)
            let registration = try await Self.registration(registrationID, participantID: participantID, on: sql)
            guard registration.installation.revokedAt == nil else {
                return registration
            }
            try await sql.raw("""
                UPDATE source_installations SET revoked_at = \(bind: max(Date(), registration.installation.createdAt))
                WHERE participant_id = \(bind: participantID) AND registration_id = \(bind: registrationID)
                """)
                .run()
            try await Self.audit(
                .sourceInstallationRevoked, registrationID: registrationID, source: registration.source, context: context, on: transaction
            )
            return try await Self.registration(registrationID, participantID: participantID, on: sql)
        }
    }
}


extension SourceInstallationService {
    private func logicalSource(
        _ repositoryKind: SourceRepositoryKind, participantID: UUID, context: AuthContext, on transaction: any Database
    ) async throws -> SourceBinding {
        let sql = try Self.sql(transaction)
        if let row = try await sql.raw("""
            SELECT * FROM source_bindings WHERE participant_id = \(bind: participantID) AND repository_kind = \(bind: repositoryKind.rawValue)
            """)
            .first() {
            let source = try SourceBinding(row: row)
            guard source.revokedAt == nil else { throw ServerError.conflict("Logical source is not active") }
            // Never attach a new installation to an identity whose recovery is unverifiable.
            _ = try await recoverKey(source: source, on: transaction)
            return source
        }
        let id = UUID()
        let keyID = UUID()
        let root = context.issuer + "/trove/sources/" + id.uuidString.lowercased()
        let systems = try SourceIdentityNamespaces.assign(root: root, keyID: keyID)
        try await sql.raw("""
            INSERT INTO source_bindings (
                id, participant_id, key_id, key_epoch, repository_kind, kind, identifier_root, event_identifier_system,
                participant_identifier_system, participant_identifier_value, created_at
            ) VALUES (
                \(bind: id), \(bind: participantID), \(bind: keyID), '1', \(bind: repositoryKind.rawValue), 'participant-app',
                \(bind: root), \(bind: systems.recordVersion.rawValue), \(bind: context.issuer + "/trove/participants"),
                \(bind: participantID.uuidString.lowercased()), \(bind: Date())
            )
            """)
            .run()
        let source = try await Self.source(id, participantID: participantID, on: sql)
        _ = try await SourceIdentityKeyStore(keyring: keyring).provision(context: source.keyContext, on: transaction)
        try await Self.audit(.sourceRegistered, registrationID: id, source: source, context: context, on: transaction)
        return source
    }

    private func recoverKey(source: SourceBinding, on transaction: any Database) async throws -> SourceIdentityKeyStore.Recovered {
        do {
            return try await SourceIdentityKeyStore(keyring: keyring).recover(
                sourceID: source.id, participantID: source.participantID, on: transaction
            )
        } catch {
            try Task.checkCancellation()
            throw ServerError(
                status: .serviceUnavailable, title: "Identity Recovery Unavailable", detail: "The retained source identity could not be recovered"
            )
        }
    }
}


extension SourceInstallationService {
    private static func sql(_ database: any Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        return sql
    }

    private static func installation(_ id: UUID, participantID: UUID, on sql: any SQLDatabase) async throws -> SourceInstallation? {
        try await sql.raw("SELECT * FROM source_installations WHERE participant_id = \(bind: participantID) AND registration_id = \(bind: id)")
            .first()
            .map { try SourceInstallation(row: $0) }
    }

    private static func source(_ id: UUID, participantID: UUID, on sql: any SQLDatabase) async throws -> SourceBinding {
        guard let row = try await sql.raw("SELECT * FROM source_bindings WHERE participant_id = \(bind: participantID) AND id = \(bind: id)").first() else {
            throw ServerError.notFound("Source binding not found")
        }
        return try SourceBinding(row: row)
    }

    private static func registration(_ id: UUID, participantID: UUID, on sql: any SQLDatabase) async throws -> Registration {
        guard let installation = try await installation(id, participantID: participantID, on: sql) else {
            throw ServerError.notFound("Source installation not found")
        }
        return try await Registration(source: source(installation.sourceID, participantID: participantID, on: sql), installation: installation)
    }

    private static func audit(
        _ action: AuditEvent.Action, registrationID: UUID, source: SourceBinding, context: AuthContext, on transaction: any Database
    ) async throws {
        let event = AuditEvent(
            context: context.auditContext,
            action: action,
            scope: .participantSource(participantID: source.participantID, sourceBindingID: source.id),
            target: .init(id: registrationID)
        )
        if action.isDisclosure {
            try await AuditRepository.recordDisclosureIntent(event, on: transaction)
        } else {
            try await AuditRepository.recordMutation(event, on: transaction)
        }
    }
}
