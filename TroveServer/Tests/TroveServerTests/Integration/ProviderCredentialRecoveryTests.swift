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


struct ProviderCredentialRecoveryTests {
    private static func expectDurableOutcome(_ current: ProviderConnection, sourceID: UUID, fails: Bool) {
        #expect(current.sourceID == sourceID)
        #expect(current.credentialVersion == (fails ? 1 : 2))
        #expect((current.credentialEnvelope == nil) == fails)
        #expect(current.refreshState == (fails ? .uncertain : .ready))
        #expect(current.status == (fails ? .reauthorizationRequired : .active))
    }

    @Test(arguments: [false, true])
    func refreshOutcomeIsDurableAndNeverReplaysAnUncertainRotation(fails: Bool) async throws {
        try await TestApp.withApp { app, _ in
            let authorization = ProviderFixture.Authorization()
            await authorization.setCredentialLifetime(60)
            let prepared = try await ProviderIngestionFixture.prepare(on: app, authorization: authorization)
            await authorization.setCredentialLifetime(600)
            if fails { await authorization.setRefreshFailure() }
            let worker = try ProviderIngestionFixture.worker(
                on: app,
                prepared: prepared,
                authorization: authorization,
                upstream: .init(measuredAt: Date()),
                validator: ClinicalEventBatchTests.validator()
            )
            let dispatch = try #require(try await worker.prepare(connectionID: prepared.connection.id, sourceToken: "getmeas:1", now: Date()))
            let service = worker.credentialService
            if fails {
                await #expect(throws: ProviderFailure.reauthorizationRequired) { try await service.credentials(for: dispatch.authority) }
            } else {
                _ = try await service.credentials(for: dispatch.authority)
            }
            #expect(await authorization.refreshes == 1)
            try await TestDatabase.withRestartedApplication(app) { reopened in
                let service = ProviderCredentialService(database: reopened.db, vault: prepared.vault, authorization: authorization)
                let current = try await ProviderSQL.connection(prepared.connection.id, on: reopened.db)
                Self.expectDurableOutcome(current, sourceID: prepared.connection.sourceID, fails: fails)
                if fails {
                    await #expect(throws: (any Error).self) { try await service.credentials(for: dispatch.authority) }
                } else {
                    _ = try await service.credentials(for: dispatch.authority)
                }
                #expect(await authorization.refreshes == 1)
            }
        }
    }

    @Test
    func aDispatchedRefreshSurvivesProcessLossWithoutASecondUpstreamRequest() async throws {
        try await TestApp.withApp { app, _ in
            let authorization = ProviderFixture.Authorization()
            let prepared = try await ProviderIngestionFixture.prepare(on: app, authorization: authorization)
            let worker = try ProviderIngestionFixture.worker(
                on: app,
                prepared: prepared,
                authorization: authorization,
                upstream: .init(measuredAt: Date()),
                validator: ClinicalEventBatchTests.validator()
            )
            let dispatch = try #require(try await worker.prepare(connectionID: prepared.connection.id, sourceToken: "getmeas:1", now: Date()))
            // The process can stop after persisting this fence and before learning whether the provider rotated its token.
            try await ProviderSQL.sql(app.db)
                .raw("""
                    UPDATE provider_connections SET refresh_state = 'dispatched', refresh_id = \(bind: UUID())
                    WHERE id = \(bind: prepared.connection.id)
                    """)
                .run()
            try await TestDatabase.withRestartedApplication(app) { reopened in
                let service = ProviderCredentialService(database: reopened.db, vault: prepared.vault, authorization: authorization)
                await #expect(throws: ProviderFailure.reauthorizationRequired) { try await service.credentials(for: dispatch.authority) }
                let current = try await ProviderSQL.connection(prepared.connection.id, on: reopened.db)
                #expect(current.refreshState == .dispatched)
                #expect(current.credentialVersion == 1)
                #expect(await authorization.refreshes == 0)
            }
        }
    }
}
