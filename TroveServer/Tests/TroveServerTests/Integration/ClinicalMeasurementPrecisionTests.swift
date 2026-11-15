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


/// Synthetic validated projections exercise SQL custody and late grants; FHIR parsing has separate tests.
struct ClinicalMeasurementPrecisionTests {
    @Test("A later study cannot acquire a point one nanosecond before its consent boundary")
    func lateAttributionUsesPersistedExactBounds() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let consent = try #require(try await EnrollmentConsent.find(fixture.consentIDs[1], on: app.db))
            let boundary = try RecordedInstant(authorityDate: #require(consent.createdAt))
            let before = try Self.precedingNanosecond(boundary)
            let bounds = try ClinicalMeasurementBounds(start: before)
            let event = try ClinicalEventStoreTests.event(source: fixture.source, measurementBounds: bounds)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let receipt = try await ClinicalEventStore(database: app.db).accept(
                    event, sourceID: fixture.source.id, targets: [fixture.targets[0]], installation: fixture.installation
                )
                let sql = try #require(app.db as? any SQLDatabase)
                let row = try #require(try await sql.raw("SELECT * FROM clinical_point_facts WHERE event_id = \(bind: receipt.eventID)").first())
                #expect(try ClinicalMeasurementBounds(row: row) == bounds)
                await #expect {
                    try await ClinicalAttributionStore(database: app.db).attribute(
                        eventID: receipt.eventID,
                        sourceID: fixture.source.id,
                        commandID: UUID(),
                        targets: [fixture.targets[1]],
                        installation: fixture.installation
                    )
                } throws: { ($0 as? ServerError)?.status.code == 403 }
                try await ClinicalEventStoreTests.expectRows(events: 1, nodes: 2, facts: 1, grants: 1, on: app.db)
            }
        }
    }

    @Test("Initial admission refuses a point one nanosecond before the first consent")
    func initialAdmissionUsesExactBounds() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, consentCount: 1)
            let consent = try #require(try await EnrollmentConsent.find(fixture.consentIDs[0], on: app.db))
            let boundary = try RecordedInstant(authorityDate: #require(consent.createdAt))
            let event = try ClinicalEventStoreTests.event(
                source: fixture.source, measurementBounds: .init(start: Self.precedingNanosecond(boundary))
            )
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                await #expect {
                    try await ClinicalEventStore(database: app.db).accept(
                        event, sourceID: fixture.source.id, targets: [fixture.targets[0]], installation: fixture.installation
                    )
                } throws: { ($0 as? ServerError)?.status.code == 403 }
                try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
            }
        }
    }
}


extension ClinicalMeasurementPrecisionTests {
    private static func precedingNanosecond(_ value: RecordedInstant) throws -> RecordedInstant {
        let nanos = try #require(Int(value.fraction.padding(toLength: 9, withPad: "0", startingAt: 0)))
        return .init(
            seconds: nanos == 0 ? value.seconds - 1 : value.seconds,
            fraction: String(format: "%09d", nanos == 0 ? 999_999_999 : nanos - 1)
        )
    }
}
