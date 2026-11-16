//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import ModelsR4
import SQLKit
import Testing
import TroveAPITypes
@testable import TroveServer


/// Synthetic admitted graph fixtures verify custody/authority; official validator evidence is separate.
struct NativeIdentifierCustodyTests {
    @Test
    func nativeUUIDSurvivesRetryAndRetractionWhileStudyGrantsRemainIndependent() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let system = try Components.Schemas.ParticipantSource(fixture.source).nativeRecordIdentifierSystem()
            let base = try LocalPointEventFixture.bytes(source: fixture.source, fixtureURL: NativeIdentifierFixture.healthKitURL())
            let bytes = try NativeIdentifierFixture.adding([["system": system.rawValue, "value": NativeIdentifierFixture.uuid]], to: base)
            let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-only")
            let targets = fixture.targets(for: event)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                let receipt = try await store.accept(event, sourceID: fixture.source.id, targets: targets, installation: fixture.installation)
                let replay = try await store.accept(event, sourceID: fixture.source.id, targets: targets, installation: fixture.installation)
                #expect(receipt == replay)
                try await ClinicalEventStoreTests.expectRows(events: 1, nodes: event.nodes.count, facts: 1, grants: 2, on: app.db)
                let sql = try #require(app.db as? any SQLDatabase)
                let row = try #require(try await sql.raw("SELECT raw_bytes FROM clinical_events WHERE id = \(bind: receipt.eventID)").first())
                #expect(try row.decode(column: "raw_bytes", as: Data.self) == bytes)
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: fixture.enrollmentIDs[0])
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 0)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 1)
                let native = Identifier(system: system.rawValue.asFHIRURIPrimitive(), value: NativeIdentifierFixture.uuid.asFHIRStringPrimitive())
                let removed = try RetractionEventFixture.bytes(activeBytes: bytes, nativeIdentifier: native)
                let retraction = try FHIRPointProjection.project(validatedBytes: removed, validatorIdentity: "test-only")
                let removedReceipt = try await store.accept(
                    retraction, sourceID: fixture.source.id, targets: [], installation: fixture.installation
                )
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 0)
                let retained = try #require(try await sql.raw("SELECT raw_bytes FROM clinical_events WHERE id = \(bind: removedReceipt.eventID)").first())
                #expect(try retained.decode(column: "raw_bytes", as: Data.self) == removed)
                try await ClinicalEventStoreTests.expectRows(
                    events: 2, nodes: event.nodes.count + retraction.nodes.count, facts: 1, grants: 2, on: app.db
                )
            }
        }
    }

    @Test(arguments: [false, true])
    func foreignNativeNamespaceCannotBeAdmittedOrRetracted(isRetraction: Bool) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let base = try LocalPointEventFixture.bytes(source: fixture.source, fixtureURL: NativeIdentifierFixture.healthKitURL())
            let foreign = "https://foreign.example/healthkit-native-record"
            let bytes: Data
            if isRetraction {
                bytes = try RetractionEventFixture.bytes(
                    activeBytes: base,
                    nativeIdentifier: Identifier(system: foreign.asFHIRURIPrimitive(), value: NativeIdentifierFixture.uuid.asFHIRStringPrimitive())
                )
            } else {
                bytes = try NativeIdentifierFixture.adding([["system": foreign, "value": NativeIdentifierFixture.uuid]], to: base)
            }
            let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-only")
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                await #expect {
                    try await ClinicalEventStore(database: app.db).accept(
                        event,
                        sourceID: fixture.source.id,
                        targets: isRetraction ? [] : fixture.targets(for: event),
                        installation: fixture.installation
                    )
                } throws: { ($0 as? ServerError)?.status.code == 403 }
            }
            try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
        }
    }
}
