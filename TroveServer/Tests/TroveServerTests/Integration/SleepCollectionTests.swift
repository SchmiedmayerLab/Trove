//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit
import Testing
import TroveAPITypes
@testable import TroveServer


/// Synthetic record identities exercise real consent, projection, custody, and study grants.
struct SleepCollectionTests {
    @Test
    func completeSleepIntervalIsStoredOnceAndGrantedToBothConsentingStudies() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, profile: CollectionObservationProfile.sleepStage.rawValue)
            let bytes = try sleepBytes(source: fixture.source)
            let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-validator")
            let receipt = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await ClinicalEventStore(database: app.db).accept(
                    event, sourceID: fixture.source.id, targets: fixture.targets(for: event), installation: fixture.installation
                )
            }
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(try await sql.raw("""
                SELECT f.effective_at, f.effective_end, f.value_kind, f.value_code, e.raw_bytes
                FROM clinical_point_facts f JOIN clinical_events e ON e.id = f.event_id
                WHERE f.event_id = \(bind: receipt.eventID)
                """)
                .first())
            let output = try #require(event.outputs.first)
            #expect(try row.decode(column: "effective_at", as: Date.self) == output.effectiveAt)
            #expect(try row.decode(column: "effective_end", as: Date.self) == output.effectiveEnd)
            #expect(try row.decode(column: "value_kind", as: String.self) == "coded")
            #expect(try row.decode(column: "value_code", as: String.self) == "deep")
            #expect(try row.decode(column: "raw_bytes", as: Data.self) == bytes)
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: event.nodes.count, facts: 1, grants: 2, on: app.db)
        }
    }

    @Test
    func heartRateConsentDoesNotAuthorizeSleep() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let event = try FHIRPointProjection.project(validatedBytes: sleepBytes(source: fixture.source), validatorIdentity: "test-validator")
            await #expect {
                try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                    try await ClinicalEventStore(database: app.db).accept(
                        event, sourceID: fixture.source.id, targets: fixture.targets(for: event), installation: fixture.installation
                    )
                }
            } throws: { ($0 as? ServerError)?.status.code == 403 }
            try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
        }
    }

    private func sleepBytes(source: SourceBinding) throws -> Data {
        let original = try LocalPointEventFixture.bytes(source: source)
        var document = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var entries = try #require(document["entry"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == "Observation" })
        var observation = try #require(entries[index]["resource"] as? [String: Any])
        observation["meta"] = ["profile": [CollectionObservationProfile.sleepStage.rawValue]]
        let measurement = ["system": "https://grovealliance.org/fhir/mobile/CodeSystem/grove-mobile-measurement", "code": "sleep-stage"]
        observation["code"] = ["coding": [measurement]]
        observation.removeValue(forKey: "effectiveDateTime")
        observation.removeValue(forKey: "valueQuantity")
        // The interval starts before both consents and ends after them, before receipt.
        let end = Date()
        observation["effectivePeriod"] = [
            "start": try TroveDateTranscoder().encode(end.addingTimeInterval(-3600)),
            "end": try TroveDateTranscoder().encode(end)
        ]
        let stage = ["system": "https://grovealliance.org/fhir/mobile/CodeSystem/grove-sleep-stage", "code": "deep"]
        observation["valueCodeableConcept"] = ["coding": [stage]]
        entries[index]["resource"] = observation
        document["entry"] = entries
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}


extension SleepCollectionTests {
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["TROVE_TEST_VALIDATOR_ASSETS"] != nil,
        "Requires the isolated, pinned full-validation integration setup"
    ))
    func healthKitSleepPassesFullValidationAndHistoricalCollectionAuthority() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(
                on: app,
                profile: CollectionObservationProfile.sleepStage.rawValue,
                measurementWindow: .init(calendar: .gregorian, timeZone: "UTC", start: .oldestSample(.init(_type: .oldestSample)))
            )
            let url = try #require(Bundle.module.url(forResource: "HealthKitSleepEvent", withExtension: "json"))
            let bytes = try ImmutablePointEventFixture.bytes(source: fixture.source, fixtureURL: url)
            let validator = try FHIRValidationClient(application: app)
            let identity = try await validator.validate(bytes)
            let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: identity)
            let output = try #require(event.outputs.first)
            let duration = try #require(output.effectiveEnd).timeIntervalSince(output.effectiveAt)
            #expect(duration == TimeInterval(28_800))
            #expect(event.rawBytes == bytes)
            #expect(String(decoding: bytes, as: UTF8.self).contains("asleepDeep"))
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                let first = try await store.accept(
                    event, sourceID: fixture.source.id, targets: fixture.targets(for: event), installation: fixture.installation
                )
                let retry = try await store.accept(
                    event, sourceID: fixture.source.id, targets: fixture.targets(for: event), installation: fixture.installation
                )
                #expect(first.eventID == retry.eventID)
                try await ClinicalEventStoreTests.expectRows(events: 1, nodes: event.nodes.count, facts: 1, grants: 2, on: app.db)
            }
        }
    }
}
