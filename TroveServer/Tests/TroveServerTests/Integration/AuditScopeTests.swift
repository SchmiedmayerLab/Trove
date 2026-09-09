//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import FluentPostgresDriver
import Foundation
import SQLKit
import Testing
@testable import TroveServer


struct AuditScopeTests {
    /// Deliberately permits invalid combinations solely to exercise the SQL boundary.
    private struct RawScope: Sendable {
        var kind: String?
        var action = "source.registered"
        var studyID: UUID?
        var groupID: UUID?
        var participantID: UUID?
        var sourceBindingID: UUID?
    }

    @Test(arguments: AuditEvent.Action.allCases)
    func actionsCannotUseTheOtherScope(action: AuditEvent.Action) {
        let wrongScope: AuditEvent.Scope = action.scopeKind == .participantSource
            ? .study(studyID: UUID())
            : .participantSource(participantID: UUID(), sourceBindingID: UUID())
        #expect(throws: AuditError.invalidScope) {
            try Self.event(action: action, scope: wrongScope).validate()
        }
    }

    @Test(arguments: AuditEvent.Action.allCases)
    func everyDeclaredActionHasOnePersistableScope(action: AuditEvent.Action) async throws {
        try await TestApp.withApp { app, _ in
            let scope: AuditEvent.Scope = action.scopeKind == .participantSource
                ? .participantSource(participantID: UUID(), sourceBindingID: UUID())
                : .study(studyID: UUID(), groupID: UUID())
            let event = Self.event(action: action, scope: scope)
            if action.isDisclosure {
                try await AuditRepository.disclose(event, on: app.db) { _ in }
            } else {
                _ = try await app.db.transaction { transaction in
                    try await AuditRepository.recordMutation(event, on: transaction)
                }
            }
            try await Self.expectCount(1, on: app.db)
        }
    }

    @Test
    func sourceRegistrationHasNoInventedStudyOrGroup() async throws {
        try await TestApp.withApp { app, _ in
            let participantID = UUID()
            let sourceID = UUID()
            let event = Self.event(action: .sourceRegistered, scope: .participantSource(participantID: participantID, sourceBindingID: sourceID))
            _ = try await app.db.transaction { transaction in
                try await AuditRepository.recordMutation(event, on: transaction)
            }
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(try await sql.raw("SELECT * FROM audit_events").first())
            #expect(try row.decode(column: "scope_kind", as: String.self) == "participant_source")
            #expect(try row.decode(column: "participant_id", as: UUID.self) == participantID)
            #expect(try row.decode(column: "source_binding_id", as: UUID.self) == sourceID)
            #expect(try row.decode(column: "study_id", as: UUID?.self) == nil)
            #expect(try row.decode(column: "group_id", as: UUID?.self) == nil)
            #expect(try row.decode(column: "action", as: String.self) == "source.registered")
            #expect(try row.decode(column: "outcome", as: String.self) == "succeeded")
        }
    }

    @Test
    func invalidScopeRollsBackMutationAndPreventsDisclosure() async throws {
        try await TestApp.withApp { app, _ in
            let groupID = UUID()
            await #expect(throws: AuditError.invalidScope) {
                try await app.db.transaction { transaction in
                    try await GroupFixtures.createGroup(on: transaction, id: groupID)
                    try await AuditRepository.recordMutation(Self.event(action: .sourceRegistered, scope: .study(studyID: UUID())), on: transaction)
                }
            }
            #expect(try await Group.find(groupID, on: app.db) == nil)
            let disclosure = Self.event(
                action: .consentPDFDisclosure, scope: .participantSource(participantID: UUID(), sourceBindingID: UUID())
            )
            await #expect(throws: AuditError.invalidScope) {
                try await AuditRepository.disclose(disclosure, on: app.db) { _ in
                    Issue.record("A mismatched audit scope must not release sensitive data")
                }
            }
            try await Self.expectCount(0, on: app.db)
        }
    }

    @Test(arguments: [
        RawScope(kind: nil, participantID: UUID(), sourceBindingID: UUID()),
        RawScope(kind: "unknown", participantID: UUID(), sourceBindingID: UUID()),
        RawScope(kind: "participant_source", sourceBindingID: UUID()),
        RawScope(kind: "participant_source", participantID: UUID()),
        RawScope(kind: "participant_source", studyID: UUID(), participantID: UUID(), sourceBindingID: UUID()),
        RawScope(kind: "participant_source", groupID: UUID(), participantID: UUID(), sourceBindingID: UUID()),
        RawScope(kind: "study", action: "consent.recorded"),
        RawScope(kind: "study", action: "consent.recorded", studyID: UUID(), participantID: UUID()),
        RawScope(kind: "study", action: "consent.recorded", studyID: UUID(), sourceBindingID: UUID()),
        RawScope(kind: "study", studyID: UUID()),
        RawScope(kind: "participant_source", action: "consent.recorded", participantID: UUID(), sourceBindingID: UUID()),
        RawScope(kind: "participant_source", action: "unregistered.action", participantID: UUID(), sourceBindingID: UUID())
    ])
    private func databaseRejectsIncompleteMixedAndUnknownScopes(row: RawScope) async throws {
        try await TestApp.withApp { app, _ in
            await #expect {
                try await Self.insert(row, on: app.db)
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            try await Self.expectCount(0, on: app.db)
        }
    }

    @Test
    func databaseAcceptsOnlyTheTwoCompleteScopeShapes() async throws {
        try await TestApp.withApp { app, _ in
            try await Self.insert(.init(kind: "study", action: "consent.recorded", studyID: UUID(), groupID: UUID()), on: app.db)
            try await Self.insert(.init(kind: "participant_source", participantID: UUID(), sourceBindingID: UUID()), on: app.db)
            try await Self.expectCount(2, on: app.db)
        }
    }

    @Test
    func sourceHistoryRemainsAppendOnlyAndOutlivesParticipantDeletion() async throws {
        try await TestApp.withApp { app, _ in
            let participant = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: "source-audit")
            let event = Self.event(
                action: .sourceRegistered,
                scope: .participantSource(participantID: try participant.requireId(), sourceBindingID: UUID())
            )
            _ = try await app.db.transaction { transaction in
                try await AuditRepository.recordMutation(event, on: transaction)
            }
            try await participant.delete(on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            await #expect(throws: (any Error).self) {
                try await sql.raw("UPDATE audit_events SET actor_subject = 'altered'").run()
            }
            await #expect(throws: (any Error).self) {
                try await sql.raw("DELETE FROM audit_events").run()
            }
            if app.db is any PostgresDatabase {
                await #expect(throws: (any Error).self) {
                    try await sql.raw("TRUNCATE audit_events").run()
                }
            }
            await #expect(throws: CreateAuditEvents.RollbackError.retainedHistory) {
                try await CreateAuditEvents().revert(on: app.db)
            }
            try await Self.expectCount(1, on: app.db)
        }
    }
}


extension AuditScopeTests {
    private static func event(action: AuditEvent.Action, scope: AuditEvent.Scope) -> AuditEvent {
        .init(
            context: .init(actor: .init(issuer: "https://identity.example/realm", subject: "participant")),
            action: action,
            scope: scope,
            target: .init(id: UUID())
        )
    }

    private static func expectCount(_ expected: Int, on database: any Database) async throws {
        let sql = try #require(database as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM audit_events").first())
        #expect(try row.decode(column: "count", as: Int.self) == expected)
    }

    private static func insert(_ row: RawScope, on database: any Database) async throws {
        let sql = try #require(database as? any SQLDatabase)
        try await sql.raw("""
            INSERT INTO audit_events (
                id, occurred_at, actor_issuer, actor_subject, action, scope_kind, study_id, group_id,
                participant_id, source_binding_id, target_id, outcome, correlation_id
            ) VALUES (
                \(bind: UUID()), \(bind: Date()), 'https://identity.example/realm', 'participant',
                \(bind: row.action), \(bind: row.kind), \(bind: row.studyID), \(bind: row.groupID),
                \(bind: row.participantID), \(bind: row.sourceBindingID), \(bind: UUID()), 'succeeded', \(bind: UUID())
            )
            """)
            .run()
    }
}
