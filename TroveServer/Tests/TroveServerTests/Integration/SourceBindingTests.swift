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
import Testing
@testable import TroveServer
import Vapor


struct SourceBindingTests {
    @Test
    func registrationBindsVerifiedAccountAndRetriesExactlyOnce() async throws {
        try await TestApp.withApp { app, _ in
            try await Self.withOwner(on: app) { service, participantID in
                let nonce = UUID()
                // Preserve the registration race without Swift 6.3's large-result async-let teardown failure.
                let (binding, retry) = try await withThrowingTaskGroup(of: SourceBinding.self) { requests in
                    requests.addTask { try await service.register(registrationID: nonce) }
                    requests.addTask { try await service.register(registrationID: nonce) }
                    let first = try #require(try await requests.next())
                    let second = try #require(try await requests.next())
                    return (first, second)
                }
                #expect(binding == retry)
                #expect(binding.registrationID == nonce)
                #expect(binding.participantID == participantID)
                #expect(binding.identifierRoot == TestApp.issuer + "/trove/sources/" + binding.id.uuidString.lowercased())
                #expect(binding.kind == .participantApp)
                #expect(binding.eventIdentifierSystem == binding.identifierRoot + "/NamingSystem/grove-event-v0")
                #expect(binding.participantIdentifierSystem == TestApp.issuer + "/trove/participants")
                #expect(binding.participantIdentifierValue == participantID.uuidString.lowercased())
                #expect(binding.revokedAt == nil)
                let loaded = try await service.find(id: binding.id)
                #expect(loaded == binding)
                try await Self.expectCount(1, table: "source_bindings", on: app.db)
                try await Self.expectCount(1, table: "audit_events", on: app.db)
                let sql = try #require(app.db as? any SQLDatabase)
                let row = try #require(try await sql.raw("SELECT * FROM audit_events").first())
                #expect(try row.decode(column: "action", as: String.self) == "source.registered")
                #expect(try row.decode(column: "participant_id", as: UUID.self) == participantID)
                #expect(try row.decode(column: "source_binding_id", as: UUID.self) == binding.id)
                #expect(try row.decode(column: "study_id", as: UUID?.self) == nil)
            }
        }
    }

    @Test(arguments: ["healthkit", "Participant-App", "", "provider"])
    func unknownStoredSourceKindFailsDecoding(kind: String) async throws {
        try await TestApp.withApp { app, _ in
            try await Self.withOwner(on: app) { service, _ in
                let binding = try await service.register(registrationID: UUID())
                let sql = try #require(app.db as? any SQLDatabase)
                // Project a corrupt value without disabling or changing schema constraints.
                let row = try #require(try await sql.raw("""
                    SELECT id, participant_id, registration_id, \(bind: kind) AS kind,
                        identifier_root, event_identifier_system, participant_identifier_system, participant_identifier_value,
                        created_at, revoked_at
                    FROM source_bindings WHERE id = \(bind: binding.id)
                    """)
                    .first())
                #expect(throws: (any Error).self) { try SourceBinding(row: row) }
                #expect(try await service.find(id: binding.id) == binding)
            }
        }
    }

    @Test
    func revokedRegistrationRetryCannotCreateOrReactivateStream() async throws {
        try await TestApp.withApp { app, _ in
            try await Self.withOwner(on: app) { service, _ in
                let nonce = UUID()
                let binding = try await service.register(registrationID: nonce)
                let revoked = try await service.revoke(id: binding.id)
                let revokedAt = try #require(revoked.revokedAt)
                #expect(revokedAt >= revoked.createdAt)
                #expect(revoked.identifierRoot == binding.identifierRoot)
                #expect(try await service.revoke(id: binding.id) == revoked)
                #expect(try await service.register(registrationID: nonce) == revoked)
                #expect(try await service.find(id: binding.id) == revoked)
                try await Self.expectCount(1, table: "source_bindings", on: app.db)
                try await Self.expectCount(2, table: "audit_events", on: app.db)
                let sql = try #require(app.db as? any SQLDatabase)
                let row = try #require(try await sql.raw("SELECT * FROM audit_events WHERE action = 'source.revoked'").first())
                #expect(try row.decode(column: "target_id", as: UUID.self) == binding.id)
            }
        }
    }

    @Test
    func matchingSubjectsFromDifferentIssuersRemainDifferentOwners() async throws {
        try await TestApp.withApp { app, _ in
            try await Self.withOwner(on: app) { service, _ in
                let nonce = UUID()
                let binding = try await service.register(registrationID: nonce)
                let otherIssuer = "https://other.example.test/realms/trove"
                let other = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderIssuer: otherIssuer)
                try await AuthContext.$current.withValue(Self.context(issuer: otherIssuer)) {
                    await #expect { try await service.find(id: binding.id) } throws: { ($0 as? ServerError)?.status.code == 404 }
                    await #expect { try await service.revoke(id: binding.id) } throws: { ($0 as? ServerError)?.status.code == 404 }
                    let separate = try await service.register(registrationID: nonce)
                    #expect(separate.id != binding.id)
                    #expect(separate.identifierRoot != binding.identifierRoot)
                    #expect(separate.eventIdentifierSystem != binding.eventIdentifierSystem)
                    #expect(separate.participantID == other.id)
                    #expect(separate.participantIdentifierSystem == otherIssuer + "/trove/participants")
                }
                #expect(try await service.find(id: binding.id) == binding)
            }
        }
    }

    @Test(arguments: [true, false])
    func missingRoleOrProfileCannotRegister(hasParticipantRole: Bool) async throws {
        try await TestApp.withApp { app, _ in
            let service = SourceBindingService(database: app.db)
            let context = Self.context(roles: hasParticipantRole ? [TestApp.participantRole] : [TestApp.researcherRole])
            await AuthContext.$current.withValue(context) {
                await #expect { try await service.register(registrationID: UUID()) } throws: {
                    ($0 as? ServerError)?.status.code == (hasParticipantRole ? 404 : 403)
                }
            }
            await #expect { try await service.register(registrationID: UUID()) } throws: { ($0 as? ServerError)?.status.code == 401 }
            try await Self.expectCount(0, table: "source_bindings", on: app.db)
            try await Self.expectCount(0, table: "audit_events", on: app.db)
        }
    }

    @Test(arguments: [true, false])
    func auditFailureRollsBackRegistrationAndRevocation(registering: Bool) async throws {
        try await TestApp.withApp { app, _ in
            try await Self.withOwner(on: app) { service, _ in
                let existing: SourceBinding? = if registering { nil } else { try await service.register(registrationID: UUID()) }
                let sql = try #require(app.db as? any SQLDatabase)
                try await sql.raw("DROP TABLE audit_events").run()
                await #expect(throws: (any Error).self) {
                    if let existing {
                        _ = try await service.revoke(id: existing.id)
                    } else {
                        _ = try await service.register(registrationID: UUID())
                    }
                }
                try await Self.expectCount(registering ? 0 : 1, table: "source_bindings", on: app.db)
                if let existing {
                    #expect(try await service.find(id: existing.id) == existing)
                }
            }
        }
    }

    @Test(arguments: [
        "registration_id = '00000000-0000-4000-8000-000000000001'",
        "kind = 'provider'", "identifier_root = 'https://other.example.test/source'", "event_identifier_system = 'urn:uuid:other'",
        "participant_identifier_system = 'https://other.example.test/participants'",
        "participant_identifier_value = 'other'", "created_at = NULL"
    ])
    func persistedIdentityCannotBeChanged(assignment: String) async throws {
        try await TestApp.withApp { app, _ in
            try await Self.withOwner(on: app) { service, _ in
                let binding = try await service.register(registrationID: UUID())
                let sql = try #require(app.db as? any SQLDatabase)
                await #expect {
                    try await sql.raw(SQLQueryString("UPDATE source_bindings SET " + assignment)).run()
                } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
                #expect(try await service.find(id: binding.id) == binding)
            }
        }
    }

    @Test
    func ownerRetentionAndRevocationTimeAreDatabaseConstraints() async throws {
        try await TestApp.withApp { app, _ in
            try await Self.withOwner(on: app) { service, participantID in
                let binding = try await service.register(registrationID: UUID())
                let other = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: "other")
                let sql = try #require(app.db as? any SQLDatabase)
                await #expect {
                    try await sql.raw("UPDATE source_bindings SET participant_id = \(bind: other.requireID())").run()
                } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
                await #expect {
                    try await sql.raw("DELETE FROM participants WHERE id = \(bind: participantID)").run()
                } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
                await #expect {
                    try await sql.raw("UPDATE source_bindings SET revoked_at = \(bind: binding.createdAt.addingTimeInterval(-60))").run()
                } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
                let revoked = try await service.revoke(id: binding.id)
                await #expect {
                    try await sql.raw("UPDATE source_bindings SET revoked_at = NULL").run()
                } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
                #expect(try await service.find(id: binding.id) == revoked)
            }
        }
    }

    @Test
    func revokedStreamCannotBeRemovedToReuseItsRegistrationNonce() async throws {
        try await TestApp.withApp { app, _ in
            try await Self.withOwner(on: app) { service, _ in
                let binding = try await service.register(registrationID: UUID())
                let revoked = try await service.revoke(id: binding.id)
                let sql = try #require(app.db as? any SQLDatabase)
                await #expect {
                    try await sql.raw("DELETE FROM source_bindings").run()
                } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
                if sql.dialect.name == "postgresql" {
                    // Bypass the foreign-key preflight, not the history trigger,
                    // within this application's disposable database.
                    await #expect {
                        try await sql.raw("TRUNCATE source_bindings CASCADE").run()
                    } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
                }
                #expect(try await service.register(registrationID: binding.registrationID) == revoked)
            }
        }
    }
}


extension SourceBindingTests {
    private static func context(issuer: String = TestApp.issuer, roles: [String] = [TestApp.participantRole]) -> AuthContext {
        .init(
            issuer: issuer,
            subject: "test-participant",
            email: "test@example.test",
            roles: roles,
            groups: [],
            researcherRole: TestApp.researcherRole,
            participantRole: TestApp.participantRole
        )
    }

    private static func withOwner(
        on app: Application, perform: @Sendable (SourceBindingService, UUID) async throws -> Void
    ) async throws {
        let participant = try await ParticipantFixtures.createParticipant(on: app.db)
        try await AuthContext.$current.withValue(context()) {
            try await perform(SourceBindingService(database: app.db), participant.requireID())
        }
    }

    private static func expectCount(_ expected: Int, table: String, on database: any Database) async throws {
        let sql = try #require(database as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM \(ident: table)").first())
        #expect(try row.decode(column: "count", as: Int.self) == expected)
    }
}
