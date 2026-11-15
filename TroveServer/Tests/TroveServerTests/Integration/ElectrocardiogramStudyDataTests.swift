//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


struct ElectrocardiogramStudyDataTests {
    @Test
    func waveformAndAverageHeartRateAreGrantedTogetherUnderTheECGRequirement() async throws {
        try await TestApp.withApp { app, _ in
            let start = try TroveDateTranscoder().decode("2026-08-17T22:00:00Z")
            let end = try TroveDateTranscoder().decode("2026-08-17T23:00:00Z")
            let requirement = CollectionRequirement(
                profile: CollectionObservationProfile.electrocardiogram.rawValue,
                sourceKind: .participantApp,
                measurementWindow: .init(calendar: .gregorian, timeZone: "UTC", start: .absolute(.init(_type: .absolute, date: start)), end: end),
                sourceTypeIdentifier: "HKDataTypeIdentifierElectrocardiogram"
            )
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, requirements: [[requirement], []])
            let url = try #require(Bundle.module.url(
                forResource: "electrocardiogram-with-symptom", withExtension: "json", subdirectory: "HealthKitComponentEvents"
            ))
            let bytes = try LocalPointEventFixture.bytes(source: fixture.source, fixtureURL: url)
            let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "synthetic-test-only")
            let waveform = try #require(event.outputs.first { $0.profile == CollectionObservationProfile.electrocardiogram.rawValue })
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                for outputs in [[waveform.fullURL], event.outputs.map(\.fullURL)] {
                    await #expect {
                        try await store.accept(
                            event,
                            sourceID: fixture.source.id,
                            targets: [.init(consentID: fixture.consentIDs[outputs.count == 1 ? 0 : 1], outputFullURLs: outputs)],
                            installation: fixture.installation
                        )
                    } throws: { ($0 as? ServerError)?.status.code == 403 }
                }
                try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
                _ = try await store.accept(
                    event, sourceID: fixture.source.id, targets: fixture.targets(for: event, studies: [0]), installation: fixture.installation
                )
                try await ClinicalEventStoreTests.expectRows(events: 1, nodes: event.nodes.count, facts: 2, grants: 2, on: app.db)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 2)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 0)
            }
        }
    }
}
