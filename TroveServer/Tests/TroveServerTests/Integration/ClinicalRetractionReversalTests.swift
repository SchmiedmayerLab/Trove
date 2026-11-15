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
import VaporTesting


struct ClinicalRetractionReversalTests {
    private static func count(_ selection: String, on database: any Database) async throws -> Int {
        let sql = try #require(database as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM \(unsafeRaw: selection)").first())
        return try row.decode(column: "count", as: Int.self)
    }

    @Test
    func deletionReportedByAnotherInstallationRetractsForEveryStudyAndCanBeReversed() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                let record = try ClinicalRecordStoreTests.event(source: fixture.source, sequence: 1, version: "1")
                _ = try await store.accept(
                    record, sourceID: fixture.source.id, targets: fixture.targets(for: record), installation: fixture.installation
                )
                // A second phone of the same participant shares the logical HealthKit source.
                let secondInstallation = UUID()
                let shared = try await SourceBindingService(database: app.db).registerSource(
                    registrationID: secondInstallation, repositoryKind: .healthKit
                )
                try #require(shared.id == fixture.source.id)
                let retraction = try ClinicalRetractionTests.retraction(source: fixture.source)
                let receipt = try await store.accept(
                    retraction, sourceID: shared.id, targets: [], installation: SourceBindingFixture.proof(secondInstallation)
                )
                for study in fixture.studyIDs { #expect(try await store.effectiveGrantCount(studyID: study) == 0) }
                #expect(try await Self.count("clinical_events", on: app.db) == 2, "Custody keeps the record and its tombstone")
                #expect(try await Self.count("clinical_point_facts", on: app.db) == 1)

                #expect(try await store.reverseRetraction(eventID: receipt.eventID, auditContext: .retractionReversal()))
                for study in fixture.studyIDs { #expect(try await store.effectiveGrantCount(studyID: study) == 1) }
                #expect(try await store.reverseRetraction(eventID: receipt.eventID, auditContext: .retractionReversal()) == false)

                // Either installation repeating the same report replays its receipt; the record stays available.
                for proof in [fixture.installation, try SourceBindingFixture.proof(secondInstallation)] {
                    #expect(try await store.accept(retraction, sourceID: shared.id, targets: [], installation: proof) == receipt)
                }
                for study in fixture.studyIDs { #expect(try await store.effectiveGrantCount(studyID: study) == 1) }
                #expect(try await Self.count("clinical_events", on: app.db) == 2, "Custody keeps the record and its tombstone")
                #expect(try await Self.count("clinical_point_facts", on: app.db) == 1)
                #expect(try await Self.count("clinical_record_retractions", on: app.db) == 1)
                #expect(try await Self.count("clinical_retraction_reversals", on: app.db) == 1)
                #expect(try await Self.count("audit_events WHERE action = 'clinical.retraction.reversed'", on: app.db) == 1)
            }
        }
    }

    @Test
    func reversalIsAppendOnlyAuditedAndLimitedToAnExistingTombstone() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let store = ClinicalEventStore(database: app.db)
            let receipt = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await store.accept(
                    ClinicalRetractionTests.retraction(source: fixture.source),
                    sourceID: fixture.source.id,
                    targets: [],
                    installation: fixture.installation
                )
            }
            await #expect { try await store.reverseRetraction(eventID: UUID(), auditContext: .retractionReversal()) }
                throws: { ($0 as? ServerError)?.status.code == 404 }
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("ALTER TABLE audit_events RENAME TO audit_events_unavailable").run()
            await #expect(throws: (any Error).self) {
                try await store.reverseRetraction(eventID: receipt.eventID, auditContext: .retractionReversal())
            }
            #expect(try await Self.count("clinical_retraction_reversals", on: app.db) == 0, "A reversal without its audit event must not persist")
            try await sql.raw("ALTER TABLE audit_events_unavailable RENAME TO audit_events").run()
            #expect(try await store.reverseRetraction(eventID: receipt.eventID, auditContext: .retractionReversal()))
            for statement in ["UPDATE clinical_retraction_reversals SET reversed_at = reversed_at", "DELETE FROM clinical_retraction_reversals"] {
                await #expect { try await sql.raw("\(unsafeRaw: statement)").run() }
                    throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            }
            #expect(try await Self.count("clinical_retraction_reversals", on: app.db) == 1)
        }
    }

    @Test
    func onlyAHealthKitSourceCanRetract() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, repositoryKind: .sensorKit)
            await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                await #expect {
                    try await ClinicalEventStore(database: app.db).accept(
                        ClinicalRetractionTests.retraction(source: fixture.source),
                        sourceID: fixture.source.id,
                        targets: [],
                        installation: fixture.installation
                    )
                } throws: { ($0 as? ServerError)?.status.code == 403 }
            }
            #expect(try await Self.count("clinical_events", on: app.db) == 0)
            #expect(try await Self.count("clinical_record_retractions", on: app.db) == 0)
        }
    }
}
