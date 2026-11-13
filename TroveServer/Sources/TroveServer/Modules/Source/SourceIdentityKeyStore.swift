//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Fluent
import Foundation
import GroveFHIRContract
import SQLKit


/// Internal storage boundary. Callers must verify the account and installation,
/// and commit the required audit event in the same transaction before disclosing recovered key material.
/// Source-row locks serialize recovery, encryption rotation and source revocation.
struct SourceIdentityKeyStore: Sendable {
    struct Recovered: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let context: SourceIdentityKeyContext
        let key: SymmetricKey

        var description: String { "RecoveredSourceIdentity(redacted)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    }

    let keyring: SourceIdentityKeyring

    /// Only initial source creation may call this operation. A duplicate identity fails instead of replacing a key.
    func provision(context: SourceIdentityKeyContext, on transaction: any Database) async throws -> Recovered {
        let sql = try Self.sql(transaction)
        let binding = try await Self.binding(sourceID: context.sourceID, participantID: context.participantID, on: sql)
        guard context.identifierRoot == binding.identifierRoot, context.keyID == binding.registrationID, context.epoch == KeyEpoch(1) else {
            throw SourceIdentityKeyring.Failure.invalidContext
        }
        let key = SymmetricKey(size: .bits256)
        let envelope = try keyring.seal(key, context: context)
        let digest = key.withUnsafeBytes { Data(SHA256.hash(data: Data($0))) }
        try await sql.raw("""
            INSERT INTO source_identity_keys (
                source_id, participant_id, key_id, epoch, identifier_root, repository_system, repository_value, key_sha256, created_at
            ) VALUES (
                \(bind: context.sourceID), \(bind: context.participantID), \(bind: context.keyID), \(bind: context.epoch.rawValue),
                \(bind: context.identifierRoot), \(bind: context.repository.system.rawValue), \(bind: context.repository.value),
                \(bind: digest), \(bind: Date())
            )
            """)
            .run()
        try await Self.append(envelope, sourceID: context.sourceID, sequence: 1, on: sql)
        return Recovered(context: context, key: key)
    }

    /// Missing, corrupt or undecryptable persisted state is an explicit recovery failure, never permission to provision.
    /// Retain the old envelope when rewrapping; the immutable key digest checks identity continuity across encryption-key retirement.
    func recover(sourceID: UUID, participantID: UUID, on transaction: any Database) async throws -> Recovered {
        let sql = try Self.sql(transaction)
        let binding = try await Self.binding(sourceID: sourceID, participantID: participantID, on: sql)
        guard let row = try await sql.raw("SELECT * FROM source_identity_keys WHERE source_id = \(bind: sourceID)").first() else {
            throw SourceIdentityKeyring.Failure.recoveryUnavailable
        }
        let context = try Self.context(row: row, binding: binding)
        guard let stored = try await sql.raw("""
            SELECT * FROM source_identity_key_envelopes WHERE source_id = \(bind: sourceID)
            ORDER BY sequence DESC LIMIT 1
            """)
            .first() else { throw SourceIdentityKeyring.Failure.recoveryUnavailable }
        let envelope = try Self.envelope(row: stored)
        let key = try keyring.open(envelope, context: context)
        let digest = key.withUnsafeBytes { Data(SHA256.hash(data: Data($0))) }
        guard digest == (try row.decode(column: "key_sha256", as: Data.self)) else {
            throw SourceIdentityKeyring.Failure.recoveryUnavailable
        }
        if envelope.encryptionKeyID != keyring.currentKeyID {
            let sequence = try stored.decode(column: "sequence", as: Int64.self)
            guard sequence > 0, sequence < Int64.max else { throw SourceIdentityKeyring.Failure.recoveryUnavailable }
            let replacement = try keyring.rewrap(envelope, context: context)
            try await Self.append(replacement, sourceID: sourceID, sequence: sequence + 1, on: sql)
        }
        return Recovered(context: context, key: key)
    }
}


extension SourceIdentityKeyStore {
    private static func sql(_ transaction: any Database) throws -> any SQLDatabase {
        guard transaction.inTransaction else { throw AuditError.transactionRequired }
        guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        return sql
    }

    private static func binding(sourceID: UUID, participantID: UUID, on sql: any SQLDatabase) async throws -> SourceBinding {
        guard let row = try await sql.raw("""
            UPDATE source_bindings SET revoked_at = revoked_at
            WHERE id = \(bind: sourceID) AND participant_id = \(bind: participantID) AND revoked_at IS NULL RETURNING *
            """)
            .first() else { throw SourceIdentityKeyring.Failure.recoveryUnavailable }
        return try SourceBinding(row: row)
    }

    private static func context(row: any SQLRow, binding: SourceBinding) throws -> SourceIdentityKeyContext {
        let context = try SourceIdentityKeyContext(
            owner: (row.decode(column: "participant_id", as: UUID.self), row.decode(column: "source_id", as: UUID.self)),
            keyID: row.decode(column: "key_id", as: UUID.self),
            epoch: KeyEpoch(row.decode(column: "epoch", as: String.self)),
            identifierRoot: row.decode(column: "identifier_root", as: String.self),
            repository: BusinessIdentifier(
                system: IdentifierSystem(row.decode(column: "repository_system", as: String.self)),
                value: row.decode(column: "repository_value", as: String.self)
            )
        )
        guard context.participantID == binding.participantID, context.sourceID == binding.id,
              context.keyID == binding.registrationID, context.epoch == KeyEpoch(1),
              context.identifierRoot == binding.identifierRoot else { throw SourceIdentityKeyring.Failure.recoveryUnavailable }
        return context
    }

    private static func envelope(row: any SQLRow) throws -> SourceIdentityKeyring.Envelope {
        try .init(
            version: row.decode(column: "version", as: Int.self),
            encryptionKeyID: row.decode(column: "encryption_key_id", as: String.self),
            sealedKey: row.decode(column: "sealed_key", as: Data.self)
        )
    }

    private static func append(_ envelope: SourceIdentityKeyring.Envelope, sourceID: UUID, sequence: Int64, on sql: any SQLDatabase) async throws {
        try await sql.raw("""
            INSERT INTO source_identity_key_envelopes (source_id, encryption_key_id, version, sealed_key, sequence, created_at)
            VALUES (\(bind: sourceID), \(bind: envelope.encryptionKeyID), \(bind: envelope.version), \(bind: envelope.sealedKey),
                \(bind: sequence), \(bind: Date()))
            """)
            .run()
    }
}
