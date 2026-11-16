//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import TroveServer


struct ProviderRegistrationIsolationTests {
    @Test("A shared logical identity cannot substitute another registration's collection authority")
    func revokedRegistrationCannotUseAnotherConnection() async throws {
        try await TestApp.withApp { app, _ in
            let authorization = ProviderFixture.Authorization()
            let prepared = try await ProviderIngestionFixture.prepare(on: app, authorization: authorization)
            let secondRegistration = try ProviderFixture.registration()
            try await ProviderRegistrationStore(database: app.db).configure(
                secondRegistration, approved: true, audit: ClinicalEventStoreTests.researcher.auditContext
            )
            let service = try ProviderFixture.service(on: app, authorization: authorization)
            let second = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let intent = try await service.start(registrationID: secondRegistration.id, redirectID: "native")
                return try await service.complete(id: intent.id, state: ProviderFixture.state(intent), code: "synthetic")
            }
            #expect(second.sourceID == prepared.connection.sourceID)
            let upstream = ProviderIngestionFixture.Upstream(measuredAt: Date().addingTimeInterval(-30))
            let worker = try ProviderIngestionFixture.worker(
                on: app, prepared: prepared, authorization: authorization, upstream: upstream, validator: ClinicalEventBatchTests.validator()
            )
            // The second registration has no exact consented demand, despite sharing the same participant's source identity.
            #expect(try await worker.run(connectionID: second.id, sourceToken: "getmeas:1") == false)
            #expect(await upstream.requests == 0)
            let dispatch = try #require(try await worker.prepare(connectionID: prepared.connection.id, sourceToken: "getmeas:1", now: Date()))
            let first = try await ProviderRegistrationStore.requireApproved(prepared.connection.registrationID, on: app.db)
            try await ProviderRegistrationStore(database: app.db).configure(
                first.configuration, approved: false, audit: ClinicalEventStoreTests.researcher.auditContext
            )
            await #expect(throws: ProviderFailure.fenced) {
                try await app.db.transaction { transaction in _ = try await dispatch.authority.lock(on: transaction) }
            }
            await #expect(throws: ProviderFailure.fenced) {
                try await worker.run(connectionID: prepared.connection.id, sourceToken: "getmeas:1")
            }
            #expect(try await worker.run(connectionID: second.id, sourceToken: "getmeas:1") == false)
            #expect(await upstream.requests == 0)
            #expect(try await ProviderSQL.sql(app.db).raw("SELECT id FROM clinical_events LIMIT 1").all().isEmpty)
        }
    }
}
