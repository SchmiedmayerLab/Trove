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


/// Synthetic admitted projections exercise real graph persistence and independent study grants.
struct ClinicalGraphStoreTests {
    @Test
    func directlyIncludedLogicalContextUsesTheSameStudyGrant() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            var event = Self.event(source: fixture.source, sequence: 1, includesContext: true)
            let context = try #require(event.questionnaireContexts.first)
            event.derivations = [.init(outputFullURL: event.outputs[0].fullURL, target: .logical(context.identifier))]
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                _ = try await store.accept(event, sourceID: fixture.source.id, targets: fixture.targets(for: event, studies: [0]))
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 1)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 0)
            }
        }
    }

    @Test(arguments: [true, false])
    func bothArrivalOrdersResolveWithoutGrantingTheOtherStudy(targetFirst: Bool) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let target = Self.event(source: fixture.source, sequence: 1, includesContext: true)
            let dependent = Self.event(source: fixture.source, sequence: 2, includesContext: false)
            let events = targetFirst ? [target, dependent] : [dependent, target]
            let receipts = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                let first = try await store.accept(events[0], sourceID: fixture.source.id, targets: fixture.targets(for: events[0], studies: [0]))
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == (targetFirst ? 1 : 0))
                let second = try await store.accept(events[1], sourceID: fixture.source.id, targets: fixture.targets(for: events[1], studies: [0]))
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 2)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 0)
                return [first, second]
            }
            try await TestDatabase.withRestartedApplication(app) { reopened in
                try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                    let store = ClinicalEventStore(database: reopened.db)
                    for (event, receipt) in zip(events, receipts) {
                        let replay = try await store.accept(event, sourceID: fixture.source.id, targets: fixture.targets(for: event, studies: [0]))
                        #expect(replay == receipt)
                    }
                    #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 2)
                    try await ClinicalEventStoreTests.expectRows(events: 2, nodes: 5, facts: 2, grants: 2, on: reopened.db)
                }
            }
        }
    }

    @Test
    func resolutionDoesNotBorrowAnotherStudysContextPermission() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                let target = Self.event(source: fixture.source, sequence: 1, includesContext: true)
                let dependent = Self.event(source: fixture.source, sequence: 2, includesContext: false)
                let receipt = try await store.accept(target, sourceID: fixture.source.id, targets: fixture.targets(for: target, studies: [1]))
                _ = try await store.accept(dependent, sourceID: fixture.source.id, targets: fixture.targets(for: dependent, studies: [0]))
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 0)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 1)
                _ = try await ClinicalAttributionStore(database: app.db).attribute(
                    eventID: receipt.eventID, sourceID: fixture.source.id, commandID: UUID(), targets: fixture.targets(for: target, studies: [0])
                )
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 2)
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: fixture.enrollmentIDs[0])
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 0)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 1)
            }
        }
    }

    @Test
    func duplicateLogicalIdentityDoesNotReplaceExactLiteralReferences() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                for sequence in 1...3 {
                    let event = Self.event(source: fixture.source, sequence: sequence, includesContext: sequence != 2)
                    _ = try await store.accept(event, sourceID: fixture.source.id, targets: fixture.targets(for: event, studies: [0]))
                }
                // Both directly included contexts stay exact; the intervening logical reference is ambiguous.
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 2)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 0)
                #expect(try await Self.count("clinical_questionnaire_contexts", on: app.db) == 2)
            }
        }
    }

    @Test
    func matchingIdentifierInAnotherOwnedSourceCannotResolveDependency() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let other = try await SourceBindingService(database: app.db).register(registrationID: UUID())
                let target = Self.event(source: other, sequence: 1, includesContext: true)
                let dependent = Self.event(source: fixture.source, sequence: 2, includesContext: false)
                let store = ClinicalEventStore(database: app.db)
                _ = try await store.accept(target, sourceID: other.id, targets: fixture.targets(for: target))
                _ = try await store.accept(dependent, sourceID: fixture.source.id, targets: fixture.targets(for: dependent))
                for study in fixture.studyIDs { #expect(try await store.effectiveGrantCount(studyID: study) == 1) }
            }
        }
    }

    @Test
    func retractedContextParentCannotSupplyPermissionToTheDependent() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                let target = Self.event(source: fixture.source, sequence: 1, includesContext: true)
                let dependent = Self.event(source: fixture.source, sequence: 2, includesContext: false)
                _ = try await store.accept(target, sourceID: fixture.source.id, targets: fixture.targets(for: target))
                _ = try await store.accept(dependent, sourceID: fixture.source.id, targets: fixture.targets(for: dependent))
                var retraction = ClinicalRetractionTests.retraction(source: fixture.source)
                retraction.retraction = .init(
                    sourceRecordIdentifier: target.outputs[0].sourceRecordIdentifier,
                    outputIdentifiers: [target.outputs[0].sourceOutputIdentifier]
                )
                _ = try await store.accept(retraction, sourceID: fixture.source.id, targets: [])
                for study in fixture.studyIDs { #expect(try await store.effectiveGrantCount(studyID: study) == 0) }
                try await ClinicalEventStoreTests.expectRows(events: 3, nodes: 6, facts: 2, grants: 4, on: app.db)
            }
        }
    }

    @Test
    func failedAuditLeavesNeitherContextNorDerivation() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("DROP TABLE audit_events").run()
            let event = Self.event(source: fixture.source, sequence: 1, includesContext: true)
            await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                await #expect(throws: (any Error).self) {
                    try await ClinicalEventStore(database: app.db).accept(event, sourceID: fixture.source.id, targets: fixture.targets(for: event))
                }
            }
            for table in ["clinical_events", "clinical_questionnaire_contexts", "clinical_point_derivations"] {
                #expect(try await Self.count(table, on: app.db) == 0)
            }
        }
    }

    @Test
    func databaseRejectsCrossEventLiteralEdgesAndPreservesImmutableGraph() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                for sequence in [1, 2] {
                    let event = Self.event(source: fixture.source, sequence: sequence, includesContext: sequence == 1)
                    _ = try await ClinicalEventStore(database: app.db).accept(
                        event, sourceID: fixture.source.id, targets: fixture.targets(for: event)
                    )
                }
            }
            let sql = try #require(app.db as? any SQLDatabase)
            await #expect {
                try await sql.raw("""
                    INSERT INTO clinical_questionnaire_contexts (node_id, event_id, source_id, identifier_system, identifier_value)
                    SELECT node_id, event_id, source_id, 'urn:response', 'wrong-resource-type' FROM clinical_point_facts
                    """)
                    .run()
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            await #expect {
                try await sql.raw("""
                    INSERT INTO clinical_point_derivations (node_id, ordinal, event_id, source_id, target_node_id)
                    SELECT d.node_id, 1, d.event_id, d.source_id, c.node_id
                    FROM clinical_point_derivations d CROSS JOIN clinical_questionnaire_contexts c
                    WHERE d.target_node_id IS NULL
                    """)
                    .run()
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            for table in ["clinical_questionnaire_contexts", "clinical_point_derivations"] {
                await #expect { try await sql.raw("UPDATE \(ident: table) SET source_id = source_id").run() }
                    throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
                await #expect { try await sql.raw("DELETE FROM \(ident: table)").run() }
                    throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            }
            #expect(try await Self.count("clinical_point_derivations", on: app.db) == 2)
        }
    }
}


extension ClinicalGraphStoreTests {
    static func event(source: SourceBinding, sequence: Int, includesContext: Bool) -> ValidatedExchangeEvent {
        var event = ClinicalRecordStoreTests.event(
            source: source, sequence: sequence, version: nil, writer: nil, record: "record-\(sequence)", outputs: ["output-\(sequence)"]
        )
        let identity = ValidatedExchangeEvent.Identifier(system: "urn:questionnaire-response", value: "response-1")
        let contextURL = "urn:context:\(sequence)"
        if includesContext {
            event = .init(
                rawBytes: event.rawBytes,
                validatorIdentity: event.validatorIdentity,
                eventIdentifierSystem: event.eventIdentifierSystem,
                eventIdentifierValue: event.eventIdentifierValue,
                producerInstance: event.producerInstance,
                participants: event.participants,
                nodes: event.nodes + [.init(ordinal: event.nodes.count, fullURL: contextURL, resourceType: "QuestionnaireResponse")],
                outputs: event.outputs,
                questionnaireContexts: [.init(fullURL: contextURL, identifier: identity)]
            )
        }
        event.derivations = [.init(outputFullURL: event.outputs[0].fullURL, target: includesContext ? .local(contextURL) : .logical(identity))]
        return event
    }

    private static func count(_ table: String, on database: any Database) async throws -> Int {
        let sql = try #require(database as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM \(ident: table)").first())
        return try row.decode(column: "count", as: Int.self)
    }
}
