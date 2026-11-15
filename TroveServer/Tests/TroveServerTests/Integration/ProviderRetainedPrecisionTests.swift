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
import TroveAPITypes
@testable import TroveServer


struct ProviderRetainedPrecisionTests {
    struct Vector: Sendable {
        let start: String
        let end: String?
        let expected: Bool
    }

    @Test(arguments: [
        Vector(start: "2025-12-31T23:59:59.999999999Z", end: nil, expected: false),
        Vector(start: "2026-01-01T00:00:00Z", end: nil, expected: true),
        Vector(start: "2026-01-01T23:59:59.999999999Z", end: nil, expected: true),
        Vector(start: "2026-01-02T00:00:00Z", end: nil, expected: false),
        Vector(start: "2025-12-31T23:00:00Z", end: "2026-01-01T00:00:00Z", expected: false),
        Vector(start: "2025-12-31T23:00:00Z", end: "2026-01-01T00:00:00.000000001Z", expected: true),
        Vector(start: "2026-01-01T00:00:00Z", end: "2026-01-01T00:00:00Z", expected: true),
        Vector(start: "2026-01-01T23:00:00Z", end: "2026-01-03T00:00:00.000000001Z", expected: false)
    ])
    func sqlPreselectionKeepsExactHalfOpenAndWholeOverlapSemantics(vector: Vector) async throws {
        try await TestApp.withApp { app, _ in
            let authorization = ProviderFixture.Authorization()
            let prepared = try await ProviderIngestionFixture.prepare(on: app, authorization: authorization)
            let connection = try await ProviderSQL.connection(prepared.connection.id, on: app.db)
            let sql = try ProviderSQL.sql(app.db)
            let codec = TroveDateTranscoder()
            let demand = try ProviderDemand(
                consentID: UUID(),
                profile: CollectionObservationProfile.bodyWeight.rawValue,
                start: codec.decode("2026-01-01T00:00:00Z"),
                end: codec.decode("2026-01-02T00:00:00Z"),
                asOf: codec.decode("2026-01-03T00:00:00Z")
            )
            let bounds = try ClinicalMeasurementBounds(sourceStart: vector.start, sourceEnd: vector.end)
            let selection = ProviderRetainedSelection(connection: connection, sourceToken: "getmeas:1", sql: sql)
            let predicate = try selection.temporalPredicate(demand)
            let row = try await sql.raw("""
                WITH f(effective_seconds, effective_fraction, effective_end_seconds, effective_end_fraction) AS (
                    VALUES (\(bind: bounds.start.seconds), \(bind: bounds.start.fraction),
                        CAST(\(bind: bounds.end?.seconds) AS BIGINT), CAST(\(bind: bounds.end?.fraction) AS TEXT))
                ) SELECT 1 AS selected FROM f WHERE \(predicate)
                """)
                .first()
            #expect((row != nil) == vector.expected)
        }
    }
}
