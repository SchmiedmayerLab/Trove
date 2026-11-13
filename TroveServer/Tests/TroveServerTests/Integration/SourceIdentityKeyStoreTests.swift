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
import Testing
@testable import TroveServer
import Vapor


struct SourceIdentityKeyStoreTests {
    private enum Rollback: Error { case requested }

    @Test
    func repeatedRecoveryAndConcurrentEncryptionRotationRetainOneIdentity() async throws {
        try await Self.withSource { app, binding in
            let originalEncryption = SymmetricKey(size: .bits256)
            let nextEncryption = SymmetricKey(size: .bits256)
            let original = SourceIdentityKeyStore(keyring: try .init(currentKeyID: "first", keys: ["first": originalEncryption]))
            let created = try await app.db.transaction { try await original.provision(context: Self.context(binding), on: $0) }
            let rotated = SourceIdentityKeyStore(keyring: try .init(
                currentKeyID: "next", keys: ["first": originalEncryption, "next": nextEncryption]
            ))
            try await withThrowingTaskGroup(of: Void.self) { tasks in
                for _ in 0..<2 {
                    tasks.addTask {
                        let recovered = try await Self.recover(rotated, binding: binding, on: app.db)
                        #expect(recovered.key == created.key)
                        #expect(recovered.context.keyID == created.context.keyID)
                        #expect(recovered.context.repository == created.context.repository)
                    }
                }
                try await tasks.waitForAll()
            }
            let restarted = SourceIdentityKeyStore(keyring: try .init(currentKeyID: "next", keys: ["next": nextEncryption]))
            #expect(try await Self.recover(restarted, binding: binding, on: app.db).key == created.key)
            try await Self.expectCounts(keys: 1, envelopes: 2, on: app.db)
            await #expect(throws: SourceIdentityKeyring.Failure.recoveryUnavailable) {
                try await Self.recover(original, binding: binding, on: app.db)
            }
        }
    }

    @Test
    func recoveryNeverCreatesMissingKeysAndRejectsForeignOrRevokedSources() async throws {
        try await Self.withSource { app, binding in
            let store = try Self.store()
            await #expect(throws: SourceIdentityKeyring.Failure.recoveryUnavailable) {
                try await Self.recover(store, binding: binding, on: app.db)
            }
            try await Self.expectCounts(keys: 0, envelopes: 0, on: app.db)
            _ = try await app.db.transaction { try await store.provision(context: Self.context(binding), on: $0) }
            await #expect(throws: SourceIdentityKeyring.Failure.recoveryUnavailable) {
                try await app.db.transaction { try await store.recover(sourceID: binding.id, participantID: UUID(), on: $0) }
            }
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("UPDATE source_bindings SET revoked_at = \(bind: Date().addingTimeInterval(1)) WHERE id = \(bind: binding.id)").run()
            await #expect(throws: SourceIdentityKeyring.Failure.recoveryUnavailable) {
                try await Self.recover(store, binding: binding, on: app.db)
            }
            try await Self.expectCounts(keys: 1, envelopes: 1, on: app.db)
        }
    }

    @Test
    func failedTransactionRetainsNeitherNewIdentityNorRotatedEnvelope() async throws {
        try await Self.withSource { app, binding in
            let encryption = SymmetricKey(size: .bits256)
            let store = SourceIdentityKeyStore(keyring: try .init(currentKeyID: "first", keys: ["first": encryption]))
            await #expect(throws: Rollback.requested) {
                try await app.db.transaction { transaction in
                    _ = try await store.provision(context: Self.context(binding), on: transaction)
                    throw Rollback.requested
                }
            }
            try await Self.expectCounts(keys: 0, envelopes: 0, on: app.db)
            let created = try await app.db.transaction { try await store.provision(context: Self.context(binding), on: $0) }
            let rotating = SourceIdentityKeyStore(keyring: try .init(
                currentKeyID: "next", keys: ["first": encryption, "next": SymmetricKey(size: .bits256)]
            ))
            await #expect(throws: Rollback.requested) {
                try await app.db.transaction { transaction in
                    _ = try await rotating.recover(sourceID: binding.id, participantID: binding.participantID, on: transaction)
                    throw Rollback.requested
                }
            }
            try await Self.expectCounts(keys: 1, envelopes: 1, on: app.db)
            #expect(try await Self.recover(store, binding: binding, on: app.db).key == created.key)
        }
    }

    @Test
    func duplicateProvisioningAndMissingTransactionCannotReplaceAnIdentity() async throws {
        try await Self.withSource { app, binding in
            let store = try Self.store()
            let context = try Self.context(binding)
            await #expect(throws: AuditError.transactionRequired) { try await store.provision(context: context, on: app.db) }
            await #expect(throws: AuditError.transactionRequired) {
                try await store.recover(sourceID: binding.id, participantID: binding.participantID, on: app.db)
            }
            let created = try await app.db.transaction { try await store.provision(context: context, on: $0) }
            await #expect(throws: (any Error).self) {
                try await app.db.transaction { try await store.provision(context: context, on: $0) }
            }
            #expect(try await Self.recover(store, binding: binding, on: app.db).key == created.key)
            try await Self.expectCounts(keys: 1, envelopes: 1, on: app.db)
            await #expect(throws: CreateSourceIdentityKeys.RollbackError.retainedIdentity) {
                try await CreateSourceIdentityKeys().revert(on: app.db)
            }
        }
    }

    @Test
    func correctlyEncryptedReplacementKeyFailsTheImmutableIdentityCommitment() async throws {
        try await Self.withSource { app, binding in
            let encryption = SymmetricKey(size: .bits256)
            let original = SourceIdentityKeyStore(keyring: try .init(currentKeyID: "first", keys: ["first": encryption]))
            let context = try Self.context(binding)
            _ = try await app.db.transaction { try await original.provision(context: context, on: $0) }
            let other = try SourceIdentityKeyring(currentKeyID: "other", keys: ["other": encryption])
            let wrong = try other.seal(SymmetricKey(size: .bits256), context: context)
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("""
                INSERT INTO source_identity_key_envelopes (source_id, encryption_key_id, version, sealed_key, sequence, created_at)
                VALUES (\(bind: binding.id), 'other', 1, \(bind: wrong.sealedKey), 2, CURRENT_TIMESTAMP)
                """)
                .run()
            await #expect(throws: SourceIdentityKeyring.Failure.recoveryUnavailable) {
                try await Self.recover(SourceIdentityKeyStore(keyring: other), binding: binding, on: app.db)
            }
            try await Self.expectCounts(keys: 1, envelopes: 2, on: app.db)
        }
    }

    @Test(arguments: ["source_identity_keys", "source_identity_key_envelopes"])
    func persistedIdentityAndEncryptionHistoryAreAppendOnly(table: String) async throws {
        try await Self.withSource { app, binding in
            let store = try Self.store()
            let created = try await app.db.transaction { try await store.provision(context: Self.context(binding), on: $0) }
            let sql = try #require(app.db as? any SQLDatabase)
            for statement in ["UPDATE \(table) SET source_id = source_id", "DELETE FROM \(table)"] {
                await #expect {
                    try await sql.raw(SQLQueryString(statement)).run()
                } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            }
            if sql.dialect.name == "postgresql" {
                await #expect {
                    try await sql.raw("TRUNCATE \(ident: table) CASCADE").run()
                } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            }
            #expect(try await Self.recover(store, binding: binding, on: app.db).key == created.key)
        }
    }
}


extension SourceIdentityKeyStoreTests {
    private static func store() throws -> SourceIdentityKeyStore {
        SourceIdentityKeyStore(keyring: try .init(currentKeyID: "current", keys: ["current": SymmetricKey(size: .bits256)]))
    }

    private static func context(_ binding: SourceBinding) throws -> SourceIdentityKeyContext {
        try .init(
            owner: (binding.participantID, binding.id),
            keyID: binding.keyID,
            epoch: KeyEpoch(1),
            identifierRoot: binding.identifierRoot,
            repository: BusinessIdentifier(system: IdentifierSystem(binding.identifierRoot + "/repository"), value: "healthkit")
        )
    }

    private static func recover(
        _ store: SourceIdentityKeyStore, binding: SourceBinding, on database: any Database
    ) async throws -> SourceIdentityKeyStore.Recovered {
        try await database.transaction { try await store.recover(sourceID: binding.id, participantID: binding.participantID, on: $0) }
    }

    private static func expectCounts(keys: Int, envelopes: Int, on database: any Database) async throws {
        let sql = try #require(database as? any SQLDatabase)
        for (table, count) in [("source_identity_keys", keys), ("source_identity_key_envelopes", envelopes)] {
            let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM \(ident: table)").first())
            #expect(try row.decode(column: "count", as: Int.self) == count)
        }
    }

    private static func withSource(_ test: @escaping @Sendable (Application, SourceBinding) async throws -> Void) async throws {
        try await TestApp.withApp { app, _ in
            _ = try await ParticipantFixtures.createParticipant(on: app.db)
            let auth = AuthContext(
                issuer: TestApp.issuer,
                subject: "test-participant",
                email: "participant@example.test",
                roles: [TestApp.participantRole],
                groups: [],
                researcherRole: TestApp.researcherRole,
                participantRole: TestApp.participantRole
            )
            let binding = try await AuthContext.$current.withValue(auth) {
                try await SourceBindingFixture.unprovisioned(on: app.db)
            }
            try await test(app, binding)
        }
    }
}
