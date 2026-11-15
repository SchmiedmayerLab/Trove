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


struct ProviderCheckpointBudgetTests {
    private struct MorePages: ProviderAcquisitionClient {
        let provider: ConnectedProvider = .withings
        let qualifiedSourceTokens: Set<String> = ["getmeas:1"]

        func fetch(_ request: ProviderAcquisitionRequest, credentials: ProviderCredentials) async throws -> ProviderAcquisitionPage {
            .init(records: [], nextCursor: "retained-next-page", complete: false, excludedRows: 0)
        }
    }

    @Test
    func failureBudgetQuiescesTheClosedWindowWithoutAdvancingItsCursor() async throws {
        try await TestApp.withApp { app, _ in
            let authorization = ProviderFixture.Authorization()
            let prepared = try await ProviderIngestionFixture.prepare(on: app, authorization: authorization)
            _ = try await ProviderReconciliationFixture.end(prepared, withdrawals: 0, on: app)
            let upstream = ProviderIngestionFixture.Upstream(measuredAt: Date())
            let worker = try ProviderIngestionFixture.worker(
                on: app, prepared: prepared, authorization: authorization, upstream: upstream, validator: ClinicalEventBatchTests.validator()
            )
            let now = Date()
            let store = ProviderWorkerStore(database: app.db, registrationIDs: [prepared.connection.registrationID], minimumDispatchInterval: 5)
            let candidate = try #require(try await store.candidates(now: now).first)
            let token = try #require(try await store.claim(candidate, tokens: ["getmeas:1"], now: now))
            _ = try #require(try await worker.prepare(connectionID: prepared.connection.id, sourceToken: token, now: now))
            let sql = try ProviderSQL.sql(app.db)
            try await sql.raw("UPDATE provider_checkpoints SET failure_count = \(bind: ProviderCheckpoint.maximumFailures - 1)").run()
            try await store.finished(candidate, sourceToken: token, outcome: .failed(.transient(nil)), now: now)
            try await Self.assertBlocked(cursor: nil, on: sql)
            let later = try await worker.collect(connectionID: prepared.connection.id, sourceToken: token, now: now.addingTimeInterval(7200))
            #expect(later != .accepted)
            #expect(await upstream.requests == 0)
        }
    }

    @Test
    func pageBudgetRetainsTheNextCursorAndDoesNotMarkIncompleteCoverageAccepted() async throws {
        try await TestApp.withApp { app, _ in
            let authorization = ProviderFixture.Authorization()
            let prepared = try await ProviderIngestionFixture.prepare(on: app, authorization: authorization)
            _ = try await ProviderReconciliationFixture.end(prepared, withdrawals: 0, on: app)
            let base = try ProviderIngestionFixture.worker(
                on: app, prepared: prepared, authorization: authorization, upstream: .init(measuredAt: Date()),
                validator: ClinicalEventBatchTests.validator()
            )
            let worker = ProviderIngestionService(
                database: base.database, validator: base.validator, credentialService: base.credentialService,
                keyring: base.keyring, worker: base.worker, facts: base.facts, limits: base.limits, client: MorePages()
            )
            _ = try #require(try await worker.prepare(connectionID: prepared.connection.id, sourceToken: "getmeas:1", now: Date()))
            let sql = try ProviderSQL.sql(app.db)
            let past = Date().addingTimeInterval(-1)
            try await sql.raw("""
                UPDATE provider_checkpoints SET page_sequence = \(bind: ProviderCheckpoint.maximumPages), lease_until = \(bind: past)
                """).run()
            try await sql.raw("UPDATE provider_connections SET next_attempt = \(bind: past)").run()
            await #expect(throws: ProviderFailure.capacityExceeded) {
                try await worker.run(connectionID: prepared.connection.id, sourceToken: "getmeas:1")
            }
            try await Self.assertBlocked(cursor: "retained-next-page", on: sql)
        }
    }

    private static func assertBlocked(cursor: String?, on sql: any SQLDatabase) async throws {
        let row = try #require(try await sql.raw("SELECT status, cursor, accepted_through FROM provider_checkpoints").first())
        #expect(try row.decode(column: "status", as: String.self) == "blocked")
        #expect(try row.decode(column: "cursor", as: String?.self) == cursor)
        #expect(try row.decode(column: "accepted_through", as: Date?.self) == nil)
        #expect(try await sql.raw("SELECT id FROM clinical_events").first() == nil)
    }
}
