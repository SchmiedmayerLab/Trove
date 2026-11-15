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


struct ProviderReconciliationTests {
    @Test(arguments: [0, 1, 2], [false, true])
    func aClosedWindowPassPreservesOverlapWithoutCollectingNewPostWindowSessions(withdrawals: Int, outside: Bool) async throws {
        try await TestApp.withApp { app, _ in
            let authorization = ProviderFixture.Authorization()
            let token = "getworkouts:interval"
            let prepared = try await ProviderIngestionFixture.prepare(
                on: app, authorization: authorization, profile: .workout, sourceToken: token,
                registration: ProviderFixture.registration(sourceTokens: [token])
            )
            let upstream = ProviderReconciliationFixture.Upstream()
            let worker = try ProviderReconciliationFixture.worker(on: app, prepared: prepared, authorization: authorization, upstream: upstream)
            #expect(try await worker.run(connectionID: prepared.connection.id, sourceToken: token))
            let end = try await ProviderReconciliationFixture.end(prepared, withdrawals: withdrawals, on: app)
            let interval = DateInterval(start: end.addingTimeInterval(outside ? 0.001 : -30), end: end.addingTimeInterval(0.002))
            await upstream.finish(interval)
            // The session becomes complete after enrollment end; the synthetic endpoint does not publish it sooner.
            try await Task.sleep(for: .milliseconds(5))
            let reconciled = try await worker.run(connectionID: prepared.connection.id, sourceToken: token)
            #expect(reconciled == (withdrawals < 2))
            #expect(await upstream.requests == (withdrawals < 2 ? 2 : 1))
            let sql = try ProviderSQL.sql(app.db)
            #expect(try await sql.raw("SELECT id FROM clinical_events").all().count == (withdrawals < 2 && !outside ? 1 : 0))
            #expect(try await sql.raw("SELECT study_id FROM study_data_grants").all().count == (outside ? 0 : 2 - withdrawals))
            if withdrawals < 2 && !outside { try await Self.verifyCompleteInterval(end: end, on: sql) }
            let later = try await worker.collect(connectionID: prepared.connection.id, sourceToken: token, now: Date().addingTimeInterval(120))
            #expect(later != .accepted)
            #expect(await upstream.requests == (withdrawals < 2 ? 2 : 1))
        }
    }

    private static func verifyCompleteInterval(end: Date, on sql: any SQLDatabase) async throws {
        let row = try #require(try await sql.raw("SELECT * FROM clinical_point_facts").first())
        let bounds = try ClinicalMeasurementBounds(row: row)
        #expect(bounds.startDate < end)
        #expect(try !bounds.ends(onOrBefore: end))
        let checkpoint = try #require(try await sql.raw("""
            SELECT status, query_as_of FROM provider_checkpoints WHERE purpose = 'reconciliation'
            """).first())
        #expect(try checkpoint.decode(column: "status", as: String.self) == "complete")
        #expect(try checkpoint.decode(column: "query_as_of", as: Date.self) > end)
    }
}
