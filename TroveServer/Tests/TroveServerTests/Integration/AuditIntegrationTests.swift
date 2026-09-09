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
import VaporTesting


struct AuditIntegrationTests {
    private enum ProbeError: Error {
        case interrupted
    }

    private static func event(action: AuditEvent.Action = .consentRecorded) -> AuditEvent {
        AuditEvent(
            context: .init(actor: .init(issuer: "https://identity.example/realm", subject: "participant-identifier")),
            action: action,
            scope: .study(studyID: UUID()),
            target: .init(id: UUID(), version: "1")
        )
    }

    private static func count(on database: any Database) async throws -> Int {
        let sql = try #require(database as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM audit_events").first())
        return try row.decode(column: "count", as: Int.self)
    }

    private static func enrollment(on app: Application) async throws -> UUID {
        let group = try await GroupFixtures.createGroup(on: app.db)
        let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
        let participant = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: "audit-participant")
        let enrollment = Enrollment(participantId: try participant.requireId(), studyId: try study.requireId(), currentRevision: 1)
        try await enrollment.save(on: app.db)
        return try enrollment.requireId()
    }

    private static func withdraw(on app: Application, enrollmentID: UUID, token: String?) async throws {
        try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(enrollmentID)/withdraw", beforeRequest: { request in
            request.bearerAuth(token)
        }) { response in
            #expect(response.status == .ok || response.status == .conflict)
        }
    }

    @Test
    func mutationRequiresExplicitTransaction() async throws {
        try await TestApp.withApp { app, _ in
            await #expect(throws: AuditError.self) {
                try await AuditRepository.recordMutation(Self.event(), on: app.db)
            }
            let auditCount = try await Self.count(on: app.db)
            #expect(auditCount == 0)
        }
    }

    @Test
    func auditInsertFailureRollsBackDomainMutation() async throws {
        try await TestApp.withApp { app, _ in
            let event = Self.event()
            _ = try await app.db.transaction { transaction in
                try await AuditRepository.recordMutation(event, on: transaction)
            }
            let groupID = UUID()
            await #expect(throws: (any Error).self) {
                try await app.db.transaction { transaction in
                    try await GroupFixtures.createGroup(on: transaction, id: groupID)
                    // Duplicate primary key is a real storage failure, not a mocked audit error.
                    try await AuditRepository.recordMutation(event, on: transaction)
                }
            }
            #expect(try await Group.find(groupID, on: app.db) == nil)
            let auditCount = try await Self.count(on: app.db)
            #expect(auditCount == 1)
        }
    }

    @Test
    func interruptedMutationRollsBackAudit() async throws {
        try await TestApp.withApp { app, _ in
            await #expect(throws: ProbeError.self) {
                try await app.db.transaction { transaction in
                    try await AuditRepository.recordMutation(Self.event(), on: transaction)
                    throw ProbeError.interrupted
                }
            }
            let auditCount = try await Self.count(on: app.db)
            #expect(auditCount == 0)
        }
    }

    @Test
    func disclosureWaitsForCommittedIntent() async throws {
        try await TestApp.withApp { app, _ in
            let event = Self.event(action: .consentPDFDisclosure)
            let result = try await AuditRepository.disclose(event, on: app.db) { receipt in
                #expect(receipt.id == event.id)
                let sql = try #require(app.db as? any SQLDatabase)
                let row = try #require(try await sql.raw("SELECT * FROM audit_events").first())
                #expect(try row.decode(column: "outcome", as: String.self) == "disclosure_intent")
                #expect(try row.decode(column: "actor_subject", as: String.self) == "participant-identifier")
                #expect(!row.contains(column: "email"))
                #expect(!row.contains(column: "token"))
                #expect(!row.contains(column: "payload"))
                return "authorized bytes"
            }
            #expect(result == "authorized bytes")
        }
    }

    @Test
    func unavailableAuditDeniesDisclosure() async throws {
        try await TestApp.withApp { app, _ in
            try await app.db.schema("audit_events").delete()
            await #expect(throws: (any Error).self) {
                try await AuditRepository.disclose(Self.event(action: .consentPDFDisclosure), on: app.db) { _ in
                    Issue.record("Sensitive release must not run when audit persistence fails")
                }
            }
        }
    }

    @Test
    func disclosureRejectsUncommittedOuterTransaction() async throws {
        try await TestApp.withApp { app, _ in
            await #expect(throws: AuditError.self) {
                try await app.db.transaction { transaction in
                    try await AuditRepository.disclose(Self.event(action: .consentPDFDisclosure), on: transaction) { _ in
                        Issue.record("Sensitive release must not run inside an outer transaction")
                    }
                }
            }
            let auditCount = try await Self.count(on: app.db)
            #expect(auditCount == 0)
        }
    }

    @Test
    func failedDeliveryRetainsIntentWithoutClaimingSuccess() async throws {
        try await TestApp.withApp { app, _ in
            await #expect(throws: ProbeError.self) {
                try await AuditRepository.disclose(Self.event(action: .consentPDFDisclosure), on: app.db) { _ in
                    throw ProbeError.interrupted
                }
            }
            let auditCount = try await Self.count(on: app.db)
            #expect(auditCount == 1)
        }
    }

    @Test
    func persistedHistoryRejectsUpdatesAndDeletion() async throws {
        try await TestApp.withApp { app, _ in
            _ = try await app.db.transaction { transaction in
                try await AuditRepository.recordMutation(Self.event(), on: transaction)
            }
            let sql = try #require(app.db as? any SQLDatabase)
            await #expect(throws: (any Error).self) {
                try await sql.raw("UPDATE audit_events SET outcome = 'altered'").run()
            }
            await #expect(throws: (any Error).self) {
                try await sql.raw("DELETE FROM audit_events").run()
            }
            if app.db is any PostgresDatabase {
                await #expect(throws: (any Error).self) {
                    try await sql.raw("TRUNCATE audit_events").run()
                }
            }
            let auditCount = try await Self.count(on: app.db)
            #expect(auditCount == 1)
        }
    }

    @Test
    func actionCannotCrossMutationAndDisclosureBoundaries() async throws {
        try await TestApp.withApp { app, _ in
            await #expect(throws: AuditError.self) {
                try await app.db.transaction { transaction in
                    try await AuditRepository.recordMutation(Self.event(action: .consentPDFDisclosure), on: transaction)
                }
            }
            await #expect(throws: AuditError.self) {
                try await AuditRepository.disclose(Self.event(), on: app.db) { _ in
                    Issue.record("Mutation action must not authorize disclosure")
                }
            }
            let auditCount = try await Self.count(on: app.db)
            #expect(auditCount == 0)
        }
    }

    @Test
    func migrationCanBeRevertedAndPreparedInAnIsolatedDatabase() async throws {
        try await TestApp.withApp { app, _ in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let groupID = try group.requireId()
            // Destructive rollback is exercised only in the disposable test database.
            try await CreateAuditEvents().revert(on: app.db)
            try await CreateAuditEvents().prepare(on: app.db)
            _ = try await app.db.transaction { transaction in
                try await AuditRepository.recordMutation(Self.event(), on: transaction)
            }
            #expect(try await Group.find(groupID, on: app.db) != nil)
            let auditCount = try await Self.count(on: app.db)
            #expect(auditCount == 1)
            let sql = try #require(app.db as? any SQLDatabase)
            await #expect(throws: (any Error).self) {
                try await sql.raw("DELETE FROM audit_events").run()
            }
        }
    }

    @Test
    func deletingDomainObjectsDoesNotCascadeIntoAuditHistory() async throws {
        try await TestApp.withApp { app, _ in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let event = AuditEvent(
                context: .init(actor: .init(issuer: "https://identity.example/realm", subject: "participant-identifier")),
                action: .consentRecorded,
                scope: .study(studyID: UUID(), groupID: try group.requireId()),
                target: .init(id: UUID(), version: "1")
            )
            _ = try await app.db.transaction { transaction in
                try await AuditRepository.recordMutation(event, on: transaction)
            }
            try await group.delete(on: app.db)
            let auditCount = try await Self.count(on: app.db)
            #expect(auditCount == 1)
        }
    }
}


extension AuditIntegrationTests {
    @Test
    func failedMigrationCanBeRetriedWithoutAnUnguardedPartialTable() async throws {
        try await TestApp.withApp { app, _ in
            try await CreateAuditEvents().revert(on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            // Index names share a schema-wide namespace on PostgreSQL and SQLite.
            // This collision fails after table creation, without mocking the database.
            try await sql.raw("CREATE TABLE audit_migration_probe (id INTEGER)").run()
            try await sql.raw("CREATE INDEX audit_events_study_time ON audit_migration_probe (id)").run()
            await #expect(throws: (any Error).self) {
                try await CreateAuditEvents().prepare(on: app.db)
            }
            await #expect(throws: (any Error).self) {
                try await sql.raw("SELECT id FROM audit_events").run()
            }
            try await sql.raw("DROP TABLE audit_migration_probe").run()
            // No manual removal of audit_events: a retry must start from a clean state.
            try await CreateAuditEvents().prepare(on: app.db)
            _ = try await app.db.transaction { transaction in
                try await AuditRepository.recordMutation(Self.event(), on: transaction)
            }
            await #expect(throws: (any Error).self) {
                try await sql.raw("UPDATE audit_events SET outcome = 'altered'").run()
            }
            await #expect(throws: (any Error).self) {
                try await sql.raw("DELETE FROM audit_events").run()
            }
            let auditCount = try await Self.count(on: app.db)
            #expect(auditCount == 1)
        }
    }

    @Test
    func auditFailurePreventsConsentResponseDisclosure() async throws {
        try await TestApp.withApp(token: .participant(subject: "audit-participant")) { app, token in
            let enrollmentID = try await Self.enrollment(on: app)
            let sentinel = "private-consent-response"
            let consent = try await RetainedRecordFixtures.consent(
                on: app.db, enrollmentID: enrollmentID, responses: .init(selects: ["private": sentinel])
            )
            try await consent.save(on: app.db)
            try await app.db.schema("audit_events").delete()
            try await app.test(.GET, "\(apiBasePath)/participant/enrollments/\(enrollmentID)/consents", beforeRequest: { request in
                request.bearerAuth(token)
            }) { response in
                #expect(response.status == .internalServerError)
                #expect(!response.body.string.contains(sentinel))
            }
        }
    }

    @Test
    func consentResponseDisclosureRecordsScopedIntentWithoutAnswers() async throws {
        try await TestApp.withApp(token: .participant(subject: "audit-participant")) { app, token in
            let enrollmentID = try await Self.enrollment(on: app)
            try await app.test(.GET, "\(apiBasePath)/participant/enrollments/\(enrollmentID)/consents", beforeRequest: { request in
                request.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)
            }
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(try await sql.raw("SELECT * FROM audit_events").first())
            #expect(try row.decode(column: "action", as: String.self) == "consent.records.disclosure")
            #expect(try row.decode(column: "target_id", as: UUID.self) == enrollmentID)
            #expect(try row.decode(column: "outcome", as: String.self) == "disclosure_intent")
            #expect(!row.contains(column: "user_responses"))
        }
    }

    @Test
    func migrationRollbackRefusesToEraseRetainedHistory() async throws {
        try await TestApp.withApp { app, _ in
            _ = try await app.db.transaction { transaction in
                try await AuditRepository.recordMutation(Self.event(), on: transaction)
            }
            await #expect(throws: CreateAuditEvents.RollbackError.retainedHistory) {
                try await CreateAuditEvents().revert(on: app.db)
            }
            let auditCount = try await Self.count(on: app.db)
            #expect(auditCount == 1)
            let sql = try #require(app.db as? any SQLDatabase)
            await #expect(throws: (any Error).self) {
                try await sql.raw("DELETE FROM audit_events").run()
            }
        }
    }

    @Test
    func auditFailureRollsBackParticipantWithdrawal() async throws {
        try await TestApp.withApp(token: .participant(subject: "audit-participant")) { app, token in
            let enrollmentID = try await Self.enrollment(on: app)
            let original = try #require(try await Enrollment.find(enrollmentID, on: app.db))
            try await app.db.schema("audit_events").delete()
            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(enrollmentID)/withdraw", beforeRequest: { request in
                request.bearerAuth(token)
            }) { response in
                #expect(response.status == .internalServerError)
            }
            let unchanged = try #require(try await Enrollment.find(enrollmentID, on: app.db))
            #expect(unchanged.withdrawnAt == nil)
            #expect(unchanged.stateVersion == original.stateVersion)
        }
    }

    @Test
    func concurrentWithdrawalsCommitOneTransitionAndAudit() async throws {
        try await TestApp.withApp(token: .participant(subject: "audit-participant")) { app, token in
            let enrollmentID = try await Self.enrollment(on: app)
            async let first: Void = Self.withdraw(on: app, enrollmentID: enrollmentID, token: token)
            async let second: Void = Self.withdraw(on: app, enrollmentID: enrollmentID, token: token)
            _ = try await (first, second)
            let withdrawn = try #require(try await Enrollment.find(enrollmentID, on: app.db))
            #expect(withdrawn.withdrawnAt != nil)
            let auditCount = try await Self.count(on: app.db)
            #expect(auditCount == 1)
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(try await sql.raw("SELECT action, target_id FROM audit_events").first())
            #expect(try row.decode(column: "action", as: String.self) == "enrollment.withdrawn")
            #expect(try row.decode(column: "target_id", as: UUID.self) == enrollmentID)
        }
    }
}
