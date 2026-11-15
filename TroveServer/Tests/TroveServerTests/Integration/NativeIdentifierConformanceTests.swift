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
import Testing
import TroveAPITypes
@testable import TroveServer


struct NativeIdentifierConformanceTests {
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["TROVE_TEST_VALIDATOR_ASSETS"] != nil,
        "Requires the isolated, pinned full-validation integration setup"
    ))
    func nativeUUIDAndRetractionPassFullValidationBeforeCustody() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let system = try Components.Schemas.ParticipantSource(fixture.source).nativeRecordIdentifierSystem()
            let original = try ImmutablePointEventFixture.bytes(source: fixture.source, fixtureURL: NativeIdentifierFixture.healthKitURL())
            let bytes = try NativeIdentifierFixture.adding([["system": system.rawValue, "value": NativeIdentifierFixture.uuid]], to: original)
            let validator = try FHIRValidationClient(application: app)
            let identity = try #require(try? await validator.validate(bytes), "Active native UUID fixture must pass full validation")
            let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: identity)
            let native = Identifier(system: system.rawValue.asFHIRURIPrimitive(), value: NativeIdentifierFixture.uuid.asFHIRStringPrimitive())
            let retracted = try RetractionEventFixture.bytes(activeBytes: bytes, nativeIdentifier: native)
            let retractionIdentity = try #require(
                try? await validator.validate(retracted), "Retraction native UUID fixture must pass full validation"
            )
            let retraction = try FHIRPointProjection.project(validatedBytes: retracted, validatorIdentity: retractionIdentity)
            #expect(event.nativeRecordIdentifiers == retraction.nativeRecordIdentifiers)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                _ = try await store.accept(
                    event, sourceID: fixture.source.id, targets: fixture.targets(for: event), installation: fixture.installation
                )
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 1)
                _ = try await store.accept(retraction, sourceID: fixture.source.id, targets: [], installation: fixture.installation)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 0)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 0)
            }
        }
    }
}
