//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import GroveProviderFHIR
import SQLKit
import Testing
@testable import TroveServer
import Vapor


enum ProviderReconciliationFixture {
    actor Upstream {
        var interval: DateInterval?
        var requests = 0
        var snapshots: [Date] = []

        func finish(_ interval: DateInterval) { self.interval = interval }

        func fetch(_ request: ProviderAcquisitionRequest) async throws -> ProviderAcquisitionPage {
            requests += 1
            snapshots.append(request.queryAsOf)
            guard let interval else {
                return .init(records: [], nextCursor: nil, complete: true, excludedRows: 0)
            }
            let bounds = try ClinicalMeasurementBounds(start: interval.start, end: interval.end)
            guard try request.demands.contains(where: {
                try bounds.includes(windowStart: $0.start, windowEnd: $0.end, asOf: $0.asOf)
            }) else { return .init(records: [], nextCursor: nil, complete: true, excludedRows: 1) }
            let evidence = try JSONEncoder().encode(interval)
            let instant = try await request.conversionInstant("late-session", evidence)
            let context = ProviderConversionContext(
                producer: request.producer,
                scope: request.scope,
                instant: instant,
                sourceTimeZone: try #require(TimeZone(secondsFromGMT: 0))
            )
            let result = try WithingsFHIR.convert(
                .workout(id: "late-session", interval: interval, activity: #require(.init(rawValue: "walking"))), context: context
            )
            let bytes = try #require(result.first?.record?.json)
            return .init(records: [bytes], nextCursor: nil, complete: true, excludedRows: 0)
        }
    }

    struct Client: ProviderAcquisitionClient {
        let upstream: Upstream
        let provider: ConnectedProvider = .withings
        let qualifiedSourceTokens: Set<String> = ["getworkouts:interval"]

        func fetch(_ request: ProviderAcquisitionRequest, credentials: ProviderCredentials) async throws -> ProviderAcquisitionPage {
            try await upstream.fetch(request)
        }
    }

    static func worker(
        on app: Application, prepared: ProviderIngestionFixture.Prepared, authorization: ProviderFixture.Authorization, upstream: Upstream
    ) throws -> ProviderIngestionService {
        let original = try ProviderIngestionFixture.worker(
            on: app,
            prepared: prepared,
            authorization: authorization,
            upstream: .init(measuredAt: Date()),
            validator: ClinicalEventBatchTests.validator()
        )
        return .init(
            database: original.database,
            validator: original.validator,
            credentialService: original.credentialService,
            keyring: original.keyring,
            worker: original.worker,
            facts: original.facts,
            limits: original.limits,
            client: Client(upstream: upstream)
        )
    }

    static func end(_ prepared: ProviderIngestionFixture.Prepared, withdrawals: Int, on app: Application) async throws -> Date {
        for id in prepared.enrollmentIDs.prefix(withdrawals) {
            _ = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: id)
            }
        }
        let end = Date()
        for id in prepared.enrollmentIDs {
            let enrollment = try #require(try await Enrollment.find(id, on: app.db))
            enrollment.endsAt = end
            try await enrollment.save(on: app.db)
        }
        try await ProviderSQL.sql(app.db).raw("UPDATE provider_connections SET next_attempt = \(bind: end)").run()
        return end
    }
}
