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


/// Repository selection tests, not evidence that a researcher disclosure route exists.
struct StudyDataQueryTests {
    @Test
    func pagesKeepCompleteRecordsAndOnlyExactGrantedOutputs() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let event = try ClinicalRecordStoreTests.event(
                source: fixture.source, sequence: 1, version: "1", outputs: ["primary", "second", "third"]
            )
            let targets = [
                fixture.targets(for: event)[0],
                ClinicalEventTarget(consentID: fixture.consentIDs[1], outputFullURLs: [event.outputs[1].fullURL])
            ]
            _ = try await Self.accept(event, fixture: fixture, targets: targets, on: app)
            let otherRecord = try ClinicalRecordStoreTests.event(
                source: fixture.source, sequence: 2, version: "1", writer: "other-writer", record: "other-record", outputs: ["fourth", "fifth"]
            )
            _ = try await Self.accept(
                otherRecord, fixture: fixture, targets: fixture.targets(for: otherRecord, studies: [0]), on: app
            )
            let query = StudyDataQuery(database: app.db)
            let all = try await query.page(studyID: fixture.studyIDs[0])
            #expect(all.outputs.count == 5 && all.nextBefore == nil)
            let first = try await query.page(studyID: fixture.studyIDs[0], limit: 1)
            let second = try await query.page(studyID: fixture.studyIDs[0], before: #require(first.nextBefore), limit: 1)
            #expect(first.outputs.map(\.nodeID) + second.outputs.map(\.nodeID) == all.outputs.map(\.nodeID))
            #expect(Set(first.outputs.map(\.eventID)).count == 1 && Set(second.outputs.map(\.eventID)).count == 1)
            #expect(Set(first.outputs.map(\.receivedAt)).count == 1 && Set(second.outputs.map(\.receivedAt)).count == 1)
            #expect(second.nextBefore == nil)
            let other = try await query.page(studyID: fixture.studyIDs[1])
            #expect(other.outputs.map(\.fullURL) == [event.outputs[1].fullURL])
            #expect(other.outputs.allSatisfy { $0.enrollmentID == fixture.enrollmentIDs[1] && $0.isCurrent })
            let foreign = try #require(all.outputs.first { $0.fullURL != event.outputs[1].fullURL }).nodeID
            for cursor in [foreign, UUID()] {
                await #expect { try await query.page(studyID: fixture.studyIDs[1], before: cursor) }
                    throws: { ($0 as? ServerError)?.status.code == 400 }
            }
        }
    }

    @Test
    func currentSelectionCannotFallBackToAnOlderGrantedRecord() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let older = try ClinicalRecordStoreTests.event(source: fixture.source, sequence: 1, version: "1", outputs: ["primary", "removed"])
            let newer = try ClinicalRecordStoreTests.event(source: fixture.source, sequence: 2, version: "2")
            let oldReceipt = try await Self.accept(older, fixture: fixture, targets: fixture.targets(for: older, studies: [0]), on: app)
            let newReceipt = try await Self.accept(newer, fixture: fixture, targets: fixture.targets(for: newer, studies: [1]), on: app)
            let query = StudyDataQuery(database: app.db)
            #expect(try await query.page(studyID: fixture.studyIDs[0]).outputs.isEmpty)
            let history = try await query.page(studyID: fixture.studyIDs[0], versions: .history)
            #expect(history.outputs.count == 2)
            #expect(history.outputs.allSatisfy { $0.eventID == oldReceipt.eventID && !$0.isCurrent })
            let current = try await query.page(studyID: fixture.studyIDs[1])
            #expect(current.outputs.count == 1)
            #expect(current.outputs.allSatisfy { $0.eventID == newReceipt.eventID && $0.isCurrent })
            let cursor = try #require(history.outputs.first).nodeID
            await #expect { try await query.page(studyID: fixture.studyIDs[0], before: cursor) }
                throws: { ($0 as? ServerError)?.status.code == 400 }
        }
    }

    @Test
    func lateAttributionReusesTheSameEventAndStableOutputBinding() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let event = try ClinicalEventStoreTests.event(source: fixture.source)
            let receipt = try await Self.accept(event, fixture: fixture, targets: [fixture.targets[0]], on: app)
            let query = StudyDataQuery(database: app.db)
            #expect(try await query.page(studyID: fixture.studyIDs[1]).outputs.isEmpty)
            let first = try #require(try await query.page(studyID: fixture.studyIDs[0]).outputs.first)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await ClinicalAttributionStore(database: app.db).attribute(
                    eventID: receipt.eventID,
                    sourceID: fixture.source.id,
                    commandID: UUID(),
                    targets: [fixture.targets[1]],
                    installation: fixture.installation
                )
            }
            let second = try #require(try await query.page(studyID: fixture.studyIDs[1]).outputs.first)
            #expect(second.nodeID == first.nodeID && second.eventID == first.eventID)
            #expect(second.outputBindingID == first.outputBindingID && second.recordID == first.recordID)
            #expect(second.enrollmentID != first.enrollmentID)
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: event.nodes.count, facts: 1, grants: 2, on: app.db)
        }
    }

    @Test
    func enrollmentEndRetainsHistoryButWithdrawalAndRetractionRemoveAccess() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let event = try ClinicalEventStoreTests.event(source: fixture.source)
            _ = try await Self.accept(event, fixture: fixture, targets: fixture.targets, on: app)
            let enrollment = try #require(try await Enrollment.find(fixture.enrollmentIDs[0], on: app.db))
            enrollment.endsAt = Date(timeIntervalSince1970: 1)
            try await enrollment.save(on: app.db)
            let query = StudyDataQuery(database: app.db)
            let first = try #require(try await query.page(studyID: fixture.studyIDs[0]).outputs.first)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: fixture.enrollmentIDs[0])
            }
            #expect(try await query.page(studyID: fixture.studyIDs[0], versions: .history).outputs.isEmpty)
            #expect(try await query.page(studyID: fixture.studyIDs[1]).outputs.count == 1)
            await #expect { try await query.page(studyID: fixture.studyIDs[0], before: first.nodeID) }
                throws: { ($0 as? ServerError)?.status.code == 400 }
            var removed = try ClinicalRetractionTests.retraction(source: fixture.source)
            removed.retraction = .init(sourceRecordIdentifier: event.outputs[0].sourceRecordIdentifier)
            _ = try await Self.accept(removed, fixture: fixture, targets: [], on: app)
            #expect(try await query.page(studyID: fixture.studyIDs[1]).outputs.isEmpty)
            #expect(try await query.page(studyID: fixture.studyIDs[1], versions: .history).outputs.isEmpty)
        }
    }

    @Test
    func logicalContextNeedsThisStudysGrantBeforeItsDependentCanBeSelected() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let context = try ClinicalGraphStoreTests.event(source: fixture.source, sequence: 1, includesContext: true)
            let dependent = try ClinicalGraphStoreTests.event(source: fixture.source, sequence: 2, includesContext: false)
            let receipt = try await Self.accept(context, fixture: fixture, targets: fixture.targets(for: context, studies: [1]), on: app)
            _ = try await Self.accept(dependent, fixture: fixture, targets: fixture.targets(for: dependent, studies: [0]), on: app)
            let query = StudyDataQuery(database: app.db)
            #expect(try await query.page(studyID: fixture.studyIDs[0]).outputs.isEmpty)
            #expect(try await query.page(studyID: fixture.studyIDs[1]).outputs.count == 1)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await ClinicalAttributionStore(database: app.db).attribute(
                    eventID: receipt.eventID,
                    sourceID: fixture.source.id,
                    commandID: UUID(),
                    targets: fixture.targets(for: context, studies: [0]),
                    installation: fixture.installation
                )
            }
            #expect(try await query.page(studyID: fixture.studyIDs[0]).outputs.count == 2)
            #expect(try await query.page(studyID: fixture.studyIDs[1]).outputs.count == 1)
        }
    }

    @Test
    func overlappingConsentRevisionsDoNotDuplicateTheMeasurement() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let event = try ClinicalEventStoreTests.event(source: fixture.source)
            let receipt = try await Self.accept(event, fixture: fixture, targets: [fixture.targets[0]], on: app)
            try await Self.addHistoricalGrant(fixture: fixture, receipt: receipt, on: app)
            let query = StudyDataQuery(database: app.db)
            let page = try await query.page(studyID: fixture.studyIDs[0], limit: 1)
            #expect(page.outputs.count == 1 && page.nextBefore == nil)
            #expect(try await query.page(studyID: fixture.studyIDs[0], versions: .history).outputs.count == 1)
            #expect(try await ClinicalEventStore(database: app.db).effectiveGrantCount(studyID: fixture.studyIDs[0]) == 1)
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: event.nodes.count, facts: 1, grants: 2, on: app.db)
            try await TestDatabase.withRestartedApplication(app) { reopened in
                let restored = try await StudyDataQuery(database: reopened.db).page(studyID: fixture.studyIDs[0])
                #expect(restored.outputs.map(\.nodeID) == page.outputs.map(\.nodeID))
                #expect(restored.outputs.map(\.enrollmentID) == page.outputs.map(\.enrollmentID))
            }
        }
    }

    @Test
    func outputBudgetStopsBetweenRecordsAndContinuesWithoutOmissions() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            for index in 1...3 {
                let event = try ClinicalRecordStoreTests.event(
                    source: fixture.source,
                    sequence: index,
                    version: "1",
                    writer: "writer-\(index)",
                    record: "record-\(index)",
                    outputs: (1...400).map { "output-\(index)-\($0)" }
                )
                _ = try await Self.accept(event, fixture: fixture, targets: fixture.targets(for: event, studies: [0]), on: app)
            }
            let query = StudyDataQuery(database: app.db)
            let first = try await query.page(studyID: fixture.studyIDs[0], limit: 3)
            let second = try await query.page(studyID: fixture.studyIDs[0], before: #require(first.nextBefore), limit: 3)
            #expect(first.outputs.count == 800 && second.outputs.count == 400 && second.nextBefore == nil)
            #expect(Set((first.outputs + second.outputs).map(\.nodeID)).count == 1200)
            #expect(Set(first.outputs.map(\.eventID)).isDisjoint(with: Set(second.outputs.map(\.eventID))))
        }
    }

    @Test
    func invalidBoundsCannotReadEvenAnEmptyStudy() async throws {
        try await TestApp.withApp { app, _ in
            let query = StudyDataQuery(database: app.db)
            for limit in [-1, 0, 101, Int.max] {
                await #expect { try await query.page(studyID: UUID(), limit: limit) }
                    throws: { ($0 as? ServerError)?.status.code == 400 }
            }
        }
    }
}


extension StudyDataQueryTests {
    static func addHistoricalGrant(
        fixture: ClinicalEventStoreTests.Fixture, receipt: ClinicalEventReceipt, on app: Application, outputs: [String] = ["urn:uuid:point"]
    ) async throws {
        let study = try #require(try await Study.find(fixture.studyIDs[0], on: app.db))
        study.collectionRequirements = [
            .init(
                profile: CollectionRequirement.supportedProfile,
                sourceKind: .participantApp,
                measurementWindow: .init(calendar: .gregorian, timeZone: "UTC", start: .last(.init(_type: .last, components: .init(month: 6))))
            )
        ]
        try await study.save(on: app.db)
        try await PublishedStudyFixtures.createNextClinicalRevision(on: app.db, studyId: fixture.studyIDs[0])
        try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            let consent = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: fixture.enrollmentIDs[0], on: app, revision: 2)
            _ = try await ClinicalAttributionStore(database: app.db).attribute(
                eventID: receipt.eventID,
                sourceID: fixture.source.id,
                commandID: UUID(),
                targets: [.init(consentID: try consent.requireID(), outputFullURLs: outputs)],
                installation: fixture.installation
            )
        }
    }

    private static func accept(
        _ event: ValidatedExchangeEvent, fixture: ClinicalEventStoreTests.Fixture, targets: [ClinicalEventTarget], on app: Application
    ) async throws -> ClinicalEventReceipt {
        try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            try await ClinicalEventStore(database: app.db).accept(
                event, sourceID: fixture.source.id, targets: targets, installation: fixture.installation
            )
        }
    }
}
