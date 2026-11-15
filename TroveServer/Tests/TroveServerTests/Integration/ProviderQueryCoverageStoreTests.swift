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


struct ProviderQueryCoverageStoreTests {
    @Test(arguments: [false, true], ["complete", "blocked", "ready"])
    func coverageReuseRequiresCompletedQueryAndSameVerifiedAccount(otherAccount: Bool, status: String) async throws {
        try await TestApp.withApp { app, _ in
            let authorization = ProviderFixture.Authorization()
            let prepared = try await ProviderIngestionFixture.prepare(on: app, authorization: authorization)
            let start = Date(timeIntervalSince1970: 1_700_000_000), end = Date(timeIntervalSince1970: 1_700_000_100)
            let demand = try ProviderDemand(consentID: UUID(), profile: "steps", start: start, end: end)
            let sql = try ProviderSQL.sql(app.db)
            let original = try await ProviderCheckpointStore(connectionID: prepared.connection.id, sourceToken: "getmeas:1", sql: sql)
            let checkpoint = try #require(try await original.next(demands: [demand], purpose: .ordinary, now: Date()))
            try await sql.raw("UPDATE provider_checkpoints SET status = \(bind: status) WHERE id = \(bind: checkpoint.id)").run()
            if otherAccount { await authorization.setAccount("different-verified-account") }
            let connection = try await ProviderRetainedFixture.newConnection(on: app, authorization: authorization)
            try await TestDatabase.withRestartedApplication(app) { reopened in
                let store = try await ProviderCheckpointStore(
                    connectionID: connection.id, sourceToken: "getmeas:1", sql: ProviderSQL.sql(reopened.db)
                )
                #expect(try await store.remainingWindow(demands: [demand], purpose: .ordinary) ==
                    ((!otherAccount && status == "complete") ? nil : start..<end))
                let energy = try ProviderDemand(consentID: demand.consentID, profile: "energy", start: start, end: end)
                let next = try #require(try await store.next(demands: [energy], purpose: .ordinary, now: Date()))
                #expect(next.coverage.selections.map(\.profile) == ["energy"])
            }
        }
    }

    @Test
    func sameWindowCanQueryANewFieldWithoutChangingAnExistingCheckpoint() async throws {
        try await TestApp.withApp { app, _ in
            let prepared = try await ProviderIngestionFixture.prepare(on: app, authorization: ProviderFixture.Authorization())
            let start = Date(timeIntervalSince1970: 1_700_000_000), end = Date(timeIntervalSince1970: 1_700_000_100)
            let steps = try ProviderDemand(consentID: UUID(), profile: "steps", start: start, end: end)
            let energy = try ProviderDemand(consentID: steps.consentID, profile: "energy", start: start, end: end)
            let sql = try ProviderSQL.sql(app.db)
            let store = try await ProviderCheckpointStore(connectionID: prepared.connection.id, sourceToken: "getmeas:1", sql: sql)
            let original = try #require(try await store.next(demands: [steps], purpose: .ordinary, now: Date()))
            try await sql.raw("UPDATE provider_checkpoints SET status = 'complete' WHERE id = \(bind: original.id)").run()
            let recovered = try await ProviderCheckpointStore(connectionID: prepared.connection.id, sourceToken: "getmeas:1", sql: sql)
            let next = try #require(try await recovered.next(demands: [steps, energy], purpose: .ordinary, now: Date()))
            #expect(next.id != original.id)
            #expect(next.window == original.window)
            #expect(next.coverage.selections.map(\.profile) == ["energy"])
            let row = try #require(try await sql.raw("SELECT * FROM provider_checkpoints WHERE id = \(bind: original.id)").first())
            #expect(try ProviderCheckpoint(row: row).coverage == original.coverage)
        }
    }
}
