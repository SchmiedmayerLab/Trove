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


struct ProviderRetainedAttributionTests {
    @Test(arguments: [false, true])
    func aNewStudyReusesTheSameVerifiedAccountWithoutCredentialsOrAnUpload(otherAccount: Bool) async throws {
        try await TestApp.withApp { app, _ in
            let collected = try await ProviderRetainedFixture.collect(on: app)
            let bytes = try await ProviderRetainedFixture.recordBytes(on: app)
            if otherAccount { await collected.authorization.setAccount("another-verified-account") }
            let connection = try await ProviderRetainedFixture.newConnection(on: app, authorization: collected.authorization)
            let retained = try await ProviderSQL.connection(connection.id, on: app.db)
            let consent = try await ProviderRetainedFixture.addStudy(on: app, prepared: collected.prepared, registrationID: retained.registrationID)
            try await ProviderRetainedFixture.retireCredentials(connectionID: connection.id, on: app)
            try await TestDatabase.withRestartedApplication(app) { reopened in
                let recovered = try ProviderIngestionFixture.worker(
                    on: reopened,
                    prepared: collected.prepared,
                    authorization: collected.authorization,
                    upstream: collected.upstream,
                    validator: ClinicalEventBatchTests.validator()
                )
                if otherAccount {
                    let reused = try await ProviderRetainedAttribution(
                        database: reopened.db, worker: collected.worker.worker, provider: .withings
                    ).run(connectionID: connection.id, sourceToken: "getmeas:1", now: Date())
                    #expect(reused == 0)
                } else {
                    #expect(try await recovered.run(connectionID: connection.id, sourceToken: "getmeas:1"))
                }
                #expect(try await ClinicalEventStore(database: reopened.db).effectiveGrantCount(studyID: consent.studyID) == (otherAccount ? 0 : 1))
                #expect(try await ProviderRetainedFixture.recordBytes(on: reopened) == bytes)
                #expect(try await ProviderRetainedFixture.count("clinical_events", on: reopened) == 1)
                let repeated = try await ProviderRetainedAttribution(
                    database: reopened.db, worker: collected.worker.worker, provider: .withings
                ).run(connectionID: connection.id, sourceToken: "getmeas:1", now: Date())
                #expect(repeated == 0)
                #expect(try await ProviderRetainedFixture.count("clinical_attribution_commands", on: reopened) == (otherAccount ? 0 : 1))
            }
            #expect(await collected.upstream.requests == 1)
            #expect(await collected.authorization.refreshes == 0)
        }
    }

    @Test(arguments: ["withdrawn", "disconnected", "registration-revoked", "audit"])
    func currentAuthorityAndMandatoryAuditFenceRetainedReuse(reason: String) async throws {
        try await TestApp.withApp { app, _ in
            let collected = try await ProviderRetainedFixture.collect(on: app)
            let prepared = collected.prepared
            let upstream = collected.upstream
            let worker = collected.worker
            let connection = try await ProviderSQL.connection(prepared.connection.id, on: app.db)
            let consent = try await ProviderRetainedFixture.addStudy(on: app, prepared: prepared, registrationID: connection.registrationID)
            let sql = try ProviderSQL.sql(app.db)
            switch reason {
            case "withdrawn":
                _ = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                    try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: consent.enrollmentID)
                }
            case "disconnected":
                try await sql.raw("UPDATE provider_connections SET status = 'disconnected' WHERE id = \(bind: connection.id)").run()
            case "registration-revoked":
                try await sql.raw("UPDATE provider_registrations SET approved = \(bind: false) WHERE id = \(bind: connection.registrationID)").run()
            default:
                try await app.db.schema("audit_events").delete()
            }
            let service = ProviderRetainedAttribution(database: app.db, worker: worker.worker, provider: .withings)
            if reason == "withdrawn" {
                #expect(try await service.run(connectionID: connection.id, sourceToken: "getmeas:1", now: Date()) == 0)
            } else {
                await #expect(throws: (any Error).self) {
                    try await service.run(connectionID: connection.id, sourceToken: "getmeas:1", now: Date())
                }
            }
            #expect(try await ProviderRetainedFixture.count("study_data_grants", on: app) == 2)
            #expect(try await ProviderRetainedFixture.count("clinical_attribution_commands", on: app) == 0)
            #expect(try await ProviderRetainedFixture.count("clinical_events", on: app) == 1)
            #expect(await upstream.requests == 1)
        }
    }
}
