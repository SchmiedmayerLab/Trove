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


struct ProviderWorkerTests {
    @Test
    func replicaBudgetAndSourceRotationSurviveRestart() async throws {
        try await TestApp.withApp { app, _ in
            let prepared = try await ProviderIngestionFixture.prepare(on: app, authorization: .init())
            let connection = try await ProviderSQL.connection(prepared.connection.id, on: app.db)
            let store = ProviderWorkerStore(database: app.db, registrationIDs: [connection.registrationID], minimumDispatchInterval: 5)
            let now = Date()
            let candidate = try #require(try await store.candidates(now: now).first)
            let tokens = candidate.registration.sourceTokens
            #expect(try await store.claim(candidate, tokens: tokens, now: now) == tokens.min())
            let replica = ProviderWorkerStore(database: app.db, registrationIDs: store.registrationIDs, minimumDispatchInterval: 5)
            #expect(try await replica.claim(candidate, tokens: tokens, now: now) == nil)
            try await TestDatabase.withRestartedApplication(app) { reopened in
                let restarted = ProviderWorkerStore(database: reopened.db, registrationIDs: store.registrationIDs, minimumDispatchInterval: 5)
                let second = try await restarted.claim(candidate, tokens: tokens, now: now.addingTimeInterval(5))
                let third = try await restarted.claim(candidate, tokens: tokens, now: now.addingTimeInterval(10))
                let wrapped = try await restarted.claim(candidate, tokens: tokens, now: now.addingTimeInterval(15))
                #expect(second == tokens.sorted()[1])
                #expect(third == tokens.sorted()[2])
                #expect(wrapped == tokens.sorted()[0])
            }
        }
    }

    @Test
    func oneRuntimeTickCollectsAndIdleSourcesDoNotRefetch() async throws {
        try await TestApp.withApp { app, _ in
            let authorization = ProviderFixture.Authorization()
            let prepared = try await ProviderIngestionFixture.prepare(on: app, authorization: authorization)
            let upstream = ProviderIngestionFixture.Upstream(measuredAt: Date().addingTimeInterval(-30))
            let worker = try ProviderIngestionFixture.worker(
                on: app, prepared: prepared, authorization: authorization, upstream: upstream, validator: ClinicalEventBatchTests.validator()
            )
            let store = ProviderWorkerStore(database: app.db, registrationIDs: [prepared.connection.registrationID], minimumDispatchInterval: 5)
            let service = ProviderWorkerService(store: store, workers: [.withings: worker])
            let now = Date()
            #expect(try await service.tick(now: now))
            #expect(await upstream.requests == 1)
            #expect(try await !service.tick(now: now.addingTimeInterval(1)))
            #expect(try await service.tick(now: now.addingTimeInterval(61)))
            #expect(await upstream.requests == 1)
            let sql = try ProviderSQL.sql(app.db)
            #expect(try await sql.raw("SELECT id FROM clinical_events").all().count == 1)
            #expect(try await sql.raw("SELECT study_id FROM study_data_grants").all().count == 2)
        }
    }

    @Test
    func retryBudgetIsPersistedWithoutAdvancingCustody() async throws {
        try await TestApp.withApp { app, _ in
            let authorization = ProviderFixture.Authorization()
            let prepared = try await ProviderIngestionFixture.prepare(on: app, authorization: authorization)
            let store = ProviderWorkerStore(database: app.db, registrationIDs: [prepared.connection.registrationID], minimumDispatchInterval: 5)
            let now = Date()
            let candidate = try #require(try await store.candidates(now: now).first)
            let token = try #require(try await store.claim(candidate, tokens: candidate.registration.sourceTokens, now: now))
            let retry = now.addingTimeInterval(7200)
            try await store.finished(candidate, sourceToken: token, outcome: .failed(.transient(retry)), now: now)
            try await TestDatabase.withRestartedApplication(app) { reopened in
                let connection = try await ProviderSQL.connection(candidate.connection.id, on: reopened.db)
                #expect(abs(connection.nextAttempt.timeIntervalSince(retry)) < 0.000_001)
                let reopenedStore = ProviderWorkerStore(database: reopened.db, registrationIDs: store.registrationIDs, minimumDispatchInterval: 5)
                #expect(try await reopenedStore.candidates(now: now.addingTimeInterval(3600)).isEmpty)
                #expect(try await ProviderSQL.sql(reopened.db).raw("SELECT id FROM clinical_events").all().isEmpty)
                #expect(try await ProviderSQL.sql(reopened.db).raw("SELECT id FROM provider_checkpoints").all().isEmpty)
            }
        }
    }
}
