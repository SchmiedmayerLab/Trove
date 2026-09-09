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
import TroveAPIServer
@testable import TroveServer
import VaporTesting


struct ClinicalAttributionTests {
    @Test
    func adoptionPreservesEarlierGrantsAndDelayedCollectionUsesItsExactConsent() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let old = try #require(try await EnrollmentConsent.find(fixture.consentIDs[0], on: app.db))
            let collectedAt = try #require(old.createdAt)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                let first = ClinicalEventStoreTests.event(source: fixture.source, effectiveAt: collectedAt)
                _ = try await store.accept(first, sourceID: fixture.source.id, targets: [fixture.targets[0]])
                try await Self.publishNextRevision(fixture, on: app)
                // Publication alone does not change which consent governs collection.
                let delayed = ClinicalEventStoreTests.event(source: fixture.source, sequence: 2, effectiveAt: collectedAt)
                let adopted = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: fixture.enrollmentIDs[0], on: app, revision: 2)
                try #require(try #require(adopted.createdAt) > collectedAt)
                _ = try await store.accept(delayed, sourceID: fixture.source.id, targets: [fixture.targets[0]])
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0], currentOnly: false) == 2)
                let current = ClinicalEventStoreTests.event(source: fixture.source, sequence: 3, effectiveAt: try #require(adopted.createdAt))
                await #expect {
                    try await store.accept(current, sourceID: fixture.source.id, targets: [fixture.targets[0]])
                } throws: { ($0 as? ServerError)?.status.code == 403 }
                let target = ClinicalEventTarget(consentID: try adopted.requireID(), outputFullURLs: ["urn:uuid:point"])
                _ = try await store.accept(current, sourceID: fixture.source.id, targets: [target])
                try await ClinicalEventStoreTests.expectRows(events: 3, nodes: 6, facts: 3, grants: 3, on: app.db)
            }
        }
    }

    @Test
    func secondStudyAttributionIsAtomicReplayableAndNeverCopiesPayload() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let event = ClinicalEventStoreTests.event(source: fixture.source)
                let receipt = try await ClinicalEventStore(database: app.db).accept(event, sourceID: fixture.source.id, targets: [fixture.targets[0]])
                let command = UUID()
                let store = ClinicalAttributionStore(database: app.db)
                async let first = store.attribute(
                    eventID: receipt.eventID, sourceID: fixture.source.id, commandID: command, targets: [fixture.targets[1]]
                )
                async let retry = store.attribute(
                    eventID: receipt.eventID, sourceID: fixture.source.id, commandID: command, targets: [fixture.targets[1]]
                )
                let outcomes = try await [first, retry]
                #expect(outcomes[0] == outcomes[1])
                #expect(outcomes[0].authorizedOutputCount == 1)
                await #expect {
                    try await store.attribute(eventID: receipt.eventID, sourceID: fixture.source.id, commandID: command, targets: fixture.targets)
                } throws: { ($0 as? ServerError)?.status.code == 409 }
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: fixture.enrollmentIDs[0])
                _ = try await app.grove[SourceBindingService.self].revoke(id: fixture.source.id)
                let revokedRetry = try await store.attribute(
                    eventID: receipt.eventID, sourceID: fixture.source.id, commandID: command, targets: [fixture.targets[1]]
                )
                #expect(revokedRetry == outcomes[0])
                await #expect {
                    try await store.attribute(eventID: receipt.eventID, sourceID: fixture.source.id, commandID: UUID(), targets: [fixture.targets[1]])
                } throws: { ($0 as? ServerError)?.status.code == 409 }
                try await Self.expectCustody(event: event, commands: 1, on: app)
                #expect(try await ClinicalEventStore(database: app.db).effectiveGrantCount(studyID: fixture.studyIDs[0]) == 0)
                #expect(try await ClinicalEventStore(database: app.db).effectiveGrantCount(studyID: fixture.studyIDs[1]) == 1)
            }
        }
    }

    @Test
    func consentStartingAfterCollectionCannotAcquireAStoredEvent() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, consentCount: 1)
            let consent = try #require(try await EnrollmentConsent.find(fixture.consentIDs[0], on: app.db))
            let event = ClinicalEventStoreTests.event(source: fixture.source, effectiveAt: try #require(consent.createdAt))
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let receipt = try await ClinicalEventStore(database: app.db).accept(event, sourceID: fixture.source.id, targets: [fixture.targets[0]])
                let later = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: fixture.enrollmentIDs[1], on: app)
                let target = ClinicalEventTarget(consentID: try later.requireID(), outputFullURLs: ["urn:uuid:point"])
                await #expect {
                    try await ClinicalAttributionStore(database: app.db).attribute(
                        eventID: receipt.eventID, sourceID: fixture.source.id, commandID: UUID(), targets: [target]
                    )
                } throws: { ($0 as? ServerError)?.status.code == 403 }
                try await ClinicalEventStoreTests.expectRows(events: 1, nodes: 2, facts: 1, grants: 1, on: app.db)
                #expect(try await Self.commandCount(on: app) == 0)
            }
        }
    }

    @Test
    func onlySelectedOutputsReceiveGrantsAndLateAttributionCanSelectACompanion() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let event = ClinicalRecordStoreTests.event(source: fixture.source, sequence: 1, version: "1", outputs: ["primary", "secondary"])
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                let receipt = try await store.accept(event, sourceID: fixture.source.id, targets: [fixture.targets[0]])
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 1)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 0)
                let target = ClinicalEventTarget(consentID: fixture.consentIDs[1], outputFullURLs: ["urn:point:secondary"])
                _ = try await ClinicalAttributionStore(database: app.db).attribute(
                    eventID: receipt.eventID, sourceID: fixture.source.id, commandID: UUID(), targets: [target]
                )
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 1)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 1)
                try await ClinicalEventStoreTests.expectRows(events: 1, nodes: 3, facts: 2, grants: 2, on: app.db)
            }
        }
    }

    @Test
    func failedAuditRollsBackLateGrantAndCommandWithoutTouchingCustody() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let event = ClinicalEventStoreTests.event(source: fixture.source)
                let receipt = try await ClinicalEventStore(database: app.db).accept(event, sourceID: fixture.source.id, targets: [fixture.targets[0]])
                try await app.db.schema("audit_events").delete()
                await #expect(throws: (any Error).self) {
                    try await ClinicalAttributionStore(database: app.db).attribute(
                        eventID: receipt.eventID, sourceID: fixture.source.id, commandID: UUID(), targets: [fixture.targets[1]]
                    )
                }
                try await ClinicalEventStoreTests.expectRows(events: 1, nodes: 2, facts: 1, grants: 1, on: app.db)
                #expect(try await Self.commandCount(on: app) == 0)
            }
        }
    }
}


extension ClinicalAttributionTests {
    private static func publishNextRevision(_ fixture: ClinicalEventStoreTests.Fixture, on app: Application) async throws {
        try await AuthContext.$current.withValue(ClinicalEventStoreTests.researcher) {
            _ = try await app.grove[PublishedStudyService.self].publish(studyId: fixture.studyIDs[0])
        }
    }

    private static func commandCount(on app: Application) async throws -> Int {
        let sql = try #require(app.db as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM clinical_attribution_commands").first())
        return try row.decode(column: "count", as: Int.self)
    }

    private static func expectCustody(event: ValidatedExchangeEvent, commands: Int, on app: Application) async throws {
        try await ClinicalEventStoreTests.expectRows(events: 1, nodes: 2, facts: 1, grants: 2, on: app.db)
        #expect(try await commandCount(on: app) == commands)
        let sql = try #require(app.db as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT raw_bytes FROM clinical_events").first())
        #expect(try row.decode(column: "raw_bytes", as: Data.self) == event.rawBytes)
    }
}
