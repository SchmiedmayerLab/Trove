//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import PostgresNIO
import SQLKit
import Testing
@testable import TroveServer
import Vapor


struct StudyDataFenceTests {
    @Test
    func requiresAnExplicitTransactionEvenForAnEmptyPage() async throws {
        try await TestApp.withApp { app, _ in
            let empty = StudyDataQuery.Page(outputs: [], nextBefore: nil)
            await #expect(throws: AuditError.transactionRequired) {
                try await StudyDataQuery(database: app.db).fence(empty, studyID: UUID())
            }
            let result = try await app.db.transaction { transaction in
                try await StudyDataQuery(database: transaction).fence(empty, studyID: UUID())
            }
            #expect(result.grants.isEmpty && result.enrollments.isEmpty && result.page.outputs.isEmpty)
        }
    }

    @Test
    func retainsEveryExactRevisionGrantWithoutOtherStudyGrants() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let event = try ClinicalEventStoreTests.event(source: fixture.source)
            let receipt = try await Self.accept(event, fixture: fixture, on: app)
            try await StudyDataQueryTests.addHistoricalGrant(fixture: fixture, receipt: receipt, on: app)
            let enrollment = try #require(try await Enrollment.find(fixture.enrollmentIDs[0], on: app.db))
            enrollment.endsAt = Date(timeIntervalSince1970: 1)
            try await enrollment.save(on: app.db)
            let result = try await app.db.transaction { transaction in
                let query = StudyDataQuery(database: transaction)
                let page = try await query.page(studyID: fixture.studyIDs[0])
                return try await query.fence(page, studyID: fixture.studyIDs[0])
            }
            #expect(result.page.outputs.count == 1)
            #expect(result.grants.count == 2 && Set(result.grants.map(\.revision)) == [1, 2])
            #expect(Set(result.grants.map(\.id)).count == 2)
            #expect(Set(result.grants.map(\.consentID)).count == 2)
            #expect(Set(result.grants.map(\.publicationID)).count == 2)
            #expect(result.grants.allSatisfy { $0.enrollmentID == fixture.enrollmentIDs[0] })
            #expect(Set(result.grants.map(\.nodeID)) == Set(result.page.outputs.map(\.nodeID)))
            #expect(result.enrollments.count == 1 && result.enrollments[0].endsAt == enrollment.endsAt)
        }
    }

    @Test
    func withdrawnOrForeignStudySelectionsCannotBeReused() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            _ = try await Self.accept(ClinicalEventStoreTests.event(source: fixture.source), fixture: fixture, on: app)
            let page = try await StudyDataQuery(database: app.db).page(studyID: fixture.studyIDs[0])
            try await Self.expectChanged(page, studyID: fixture.studyIDs[1], on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: fixture.enrollmentIDs[0])
            }
            try await Self.expectChanged(page, studyID: fixture.studyIDs[0], on: app)
            #expect(try await StudyDataQuery(database: app.db).page(studyID: fixture.studyIDs[1]).outputs.count == 1)
        }
    }

    @Test
    func supersededAndRetractedCandidatesRequireARefresh() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let older = try ClinicalRecordStoreTests.event(source: fixture.source, sequence: 1, version: "1")
            _ = try await Self.accept(older, fixture: fixture, on: app)
            let query = StudyDataQuery(database: app.db)
            let before = try await query.page(studyID: fixture.studyIDs[0])
            _ = try await Self.accept(ClinicalRecordStoreTests.event(source: fixture.source, sequence: 2, version: "2"), fixture: fixture, on: app)
            try await Self.expectChanged(before, studyID: fixture.studyIDs[0], on: app)
            let history = try await query.page(studyID: fixture.studyIDs[0], versions: .history)
            #expect(history.outputs.count == 2)
            var removed = try ClinicalRetractionTests.retraction(source: fixture.source)
            removed.retraction = .init(sourceRecordIdentifier: older.outputs[0].sourceRecordIdentifier)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await ClinicalEventStore(database: app.db).accept(
                    removed, sourceID: fixture.source.id, targets: [], installation: fixture.installation
                )
            }
            try await Self.expectChanged(history, studyID: fixture.studyIDs[0], on: app, versions: .history)
        }
    }

    @Test
    func lateAttributionDoesNotRefillTheCapturedPage() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let event = try ClinicalRecordStoreTests.event(source: fixture.source, sequence: 1, version: "1", outputs: ["primary", "second"])
            let receipt = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await ClinicalEventStore(database: app.db).accept(
                    event,
                    sourceID: fixture.source.id,
                    targets: [.init(consentID: fixture.consentIDs[0], outputFullURLs: [event.outputs[0].fullURL]), fixture.targets(for: event)[1]],
                    installation: fixture.installation
                )
            }
            let page = try await StudyDataQuery(database: app.db).page(studyID: fixture.studyIDs[0])
            #expect(page.outputs.count == 1)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await ClinicalAttributionStore(database: app.db).attribute(
                    eventID: receipt.eventID,
                    sourceID: fixture.source.id,
                    commandID: UUID(),
                    targets: fixture.targets(for: event, studies: [0]),
                    installation: fixture.installation
                )
            }
            let result = try await app.db.transaction { transaction in
                try await StudyDataQuery(database: transaction).fence(page, studyID: fixture.studyIDs[0])
            }
            #expect(result.page.outputs == page.outputs && result.grants.count == 1)
            #expect(try await StudyDataQuery(database: app.db).page(studyID: fixture.studyIDs[0]).outputs.count == 2)
        }
    }

    @Test(.enabled(if: Environment.get("TROVE_TEST_POSTGRES_PORT") != nil, "Requires isolated PostgreSQL row locks"))
    func participantAndEnrollmentLocksRemainHeldUntilTransactionCommit() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            _ = try await Self.accept(ClinicalEventStoreTests.event(source: fixture.source), fixture: fixture, on: app)
            let page = try await StudyDataQuery(database: app.db).page(studyID: fixture.studyIDs[0])
            let output = try #require(page.outputs.first)
            try await app.db.transaction { transaction in
                _ = try await StudyDataQuery(database: transaction).fence(page, studyID: fixture.studyIDs[0])
                for (table, id) in [("participants", output.participantID), ("enrollments", output.enrollmentID)] {
                    await #expect {
                        try await Self.competingLock(table: table, id: id, on: app)
                    } throws: { ($0 as? PSQLError)?.serverInfo?[.sqlState] == "55P03" }
                }
            }
            try await Self.competingLock(table: "participants", id: output.participantID, on: app)
            try await Self.competingLock(table: "enrollments", id: output.enrollmentID, on: app)
        }
    }
}


extension StudyDataFenceTests {
    private static func competingLock(table: String, id: UUID, on app: Application) async throws {
        try await app.db.transaction { transaction in
            let sql = try #require(transaction as? any SQLDatabase)
            let row = try await sql.raw("SELECT id FROM \(ident: table) WHERE id = \(bind: id) FOR UPDATE NOWAIT").first()
            #expect(row != nil)
        }
    }

    private static func accept(
        _ event: ValidatedExchangeEvent, fixture: ClinicalEventStoreTests.Fixture, on app: Application
    ) async throws -> ClinicalEventReceipt {
        try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            try await ClinicalEventStore(database: app.db).accept(
                event, sourceID: fixture.source.id, targets: fixture.targets(for: event), installation: fixture.installation
            )
        }
    }

    private static func expectChanged(
        _ page: StudyDataQuery.Page, studyID: UUID, on app: Application, versions: StudyDataQuery.Versions = .current
    ) async throws {
        await #expect {
            try await app.db.transaction { transaction in
                try await StudyDataQuery(database: transaction).fence(page, studyID: studyID, versions: versions)
            }
        } throws: { ($0 as? ServerError)?.status.code == 409 }
    }
}
