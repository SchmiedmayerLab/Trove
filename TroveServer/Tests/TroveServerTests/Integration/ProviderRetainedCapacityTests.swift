//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Testing
@testable import TroveServer


struct ProviderRetainedCapacityTests {
    @Test
    func boundedPassesFinishWithoutReadingOrUploadingThePayloadAgain() async throws {
        try await TestApp.withApp { app, _ in
            let count = ProviderRetainedAttribution.maximumRecordsPerPass + 1
            let collected = try await ProviderRetainedFixture.collect(on: app, recordCount: count)
            let connection = try await ProviderSQL.connection(collected.prepared.connection.id, on: app.db)
            let consent = try await ProviderRetainedFixture.addStudy(
                on: app, prepared: collected.prepared, registrationID: connection.registrationID
            )
            let service = ProviderRetainedAttribution(database: app.db, worker: collected.worker.worker, provider: .withings)
            #expect(try await service.run(connectionID: connection.id, sourceToken: "getmeas:1", now: Date()) == count - 1)
            #expect(try await ClinicalEventStore(database: app.db).effectiveGrantCount(studyID: consent.studyID) == count - 1)
            #expect(try await service.run(connectionID: connection.id, sourceToken: "getmeas:1", now: Date()) == 1)
            #expect(try await service.run(connectionID: connection.id, sourceToken: "getmeas:1", now: Date()) == 0)
            #expect(try await ClinicalEventStore(database: app.db).effectiveGrantCount(studyID: consent.studyID) == count)
            #expect(try await ProviderRetainedFixture.count("clinical_events", on: app) == count)
            #expect(try await ProviderRetainedFixture.count("clinical_attribution_commands", on: app) == count)
            #expect(await collected.upstream.requests == 1)
        }
    }
}
