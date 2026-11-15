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
import Vapor


/// Synthetic upstream/validator boundaries exercise production conversion, durable staging, consent and custody together.
struct ProviderIngestionTests {
    enum Recovery: CaseIterable, Sendable {
        case active
        case ended
        case endedWithoutCredentials
    }

    @Test(arguments: [false, true], Recovery.allCases)
    func stagedPageSurvivesRestartAndRechecksIndependentStudyDemand(withdrawFirstStudy: Bool, recovery: Recovery) async throws {
        try await TestApp.withApp { app, _ in
            let authorization = ProviderFixture.Authorization()
            let prepared = try await ProviderIngestionFixture.prepare(on: app, authorization: authorization)
            let upstream = ProviderIngestionFixture.Upstream(measuredAt: Date().addingTimeInterval(-30))
            let interruption = ProviderIngestionFixture.ValidationInterruption()
            let worker = try ProviderIngestionFixture.worker(
                on: app, prepared: prepared, authorization: authorization, upstream: upstream,
                validator: ClinicalEventBatchTests.validator { try await interruption.check() }
            )
            await #expect(throws: (any Error).self) {
                try await worker.run(connectionID: prepared.connection.id, sourceToken: "getmeas:1")
            }
            #expect(await upstream.requests == 1)
            let sql = try ProviderSQL.sql(app.db)
            let exactBytes = try await Self.requireStagedRecord(on: sql)
            let sourceEvidence = try await Self.sourceEvidence(on: app.db)
            try await Self.changeEnrollmentAndExpireLease(
                on: app, prepared: prepared, withdrawFirstStudy: withdrawFirstStudy, recovery: recovery
            )
            try await TestDatabase.withRestartedApplication(app) { reopened in
                let recovered = try ProviderIngestionFixture.worker(
                    on: reopened, prepared: prepared, authorization: authorization, upstream: upstream,
                    validator: ClinicalEventBatchTests.validator()
                )
                #expect(try await recovered.run(connectionID: prepared.connection.id, sourceToken: "getmeas:1"))
                #expect(await upstream.requests == 1)
                #expect(try await Self.sourceEvidence(on: reopened.db) == sourceEvidence)
                try await Self.verifyCustody(
                    on: reopened, prepared: prepared, exactBytes: exactBytes, withdrawFirstStudy: withdrawFirstStudy
                )
                try await Self.verifyClosedWindowRecovery(recovered, upstream: upstream, prepared: prepared, recovery: recovery)
            }
        }
    }

    private static func verifyClosedWindowRecovery(
        _ recovered: ProviderIngestionService, upstream: ProviderIngestionFixture.Upstream,
        prepared: ProviderIngestionFixture.Prepared, recovery: Recovery
    ) async throws {
        if recovery != .active {
            let next = Date().addingTimeInterval(120)
            let reconciled = try await recovered.run(connectionID: prepared.connection.id, sourceToken: "getmeas:1", now: next)
            #expect(reconciled == (recovery == .ended))
            #expect(await upstream.requests == (recovery == .ended ? 2 : 1))
            #expect(try await !recovered.run(
                connectionID: prepared.connection.id, sourceToken: "getmeas:1", now: next.addingTimeInterval(120)
            ))
        }
    }

    private static func changeEnrollmentAndExpireLease(
        on app: Application, prepared: ProviderIngestionFixture.Prepared, withdrawFirstStudy: Bool, recovery: Recovery
    ) async throws {
        let sql = try ProviderSQL.sql(app.db)
        if withdrawFirstStudy {
            _ = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: prepared.enrollmentIDs[0])
            }
        }
        if recovery != .active {
            for id in prepared.enrollmentIDs {
                let enrollment = try #require(try await Enrollment.find(id, on: app.db))
                enrollment.endsAt = Date()
                try await enrollment.save(on: app.db)
            }
        }
        if recovery == .endedWithoutCredentials {
            try await sql.raw("""
                UPDATE provider_connections SET status = 'reauthorization-required', refresh_state = 'uncertain', credential_envelope = NULL
                """).run()
        }
        // Simulate expiry of the abandoned dispatch lease; queued bytes and identities are unchanged.
        let past = Date().addingTimeInterval(-1)
        try await sql.raw("UPDATE provider_checkpoints SET lease_until = \(bind: past)").run()
        try await sql.raw("UPDATE provider_connections SET next_attempt = \(bind: past)").run()
    }

    private static func sourceEvidence(on database: any Database) async throws -> Data {
        let row = try #require(try await ProviderSQL.sql(database).raw("SELECT source_evidence FROM provider_conversion_instants").first())
        return try row.decode(column: "source_evidence", as: Data.self)
    }

    private static func requireStagedRecord(on sql: any SQLDatabase) async throws -> Data {
        let staged = try #require(try await sql.raw("SELECT status, cursor, accepted_through FROM provider_checkpoints").first())
        #expect(try staged.decode(column: "status", as: String.self) == "staged")
        #expect(try staged.decode(column: "cursor", as: String?.self) == nil)
        #expect(try staged.decode(column: "accepted_through", as: Date?.self) == nil)
        let original = try #require(try await sql.raw("SELECT record_bytes FROM provider_staged_records").first())
        let exactBytes = try original.decode(column: "record_bytes", as: Data.self)
        #expect(try await sql.raw("SELECT id FROM clinical_events").first() == nil)
        return exactBytes
    }

    private static func verifyCustody(
        on reopened: Application, prepared: ProviderIngestionFixture.Prepared, exactBytes: Data, withdrawFirstStudy: Bool
    ) async throws {
        let reopenedSQL = try ProviderSQL.sql(reopened.db)
        let records = try await reopenedSQL.raw("SELECT raw_bytes FROM clinical_events").all()
        #expect(records.count == 1)
        #expect(try records.first?.decode(column: "raw_bytes", as: Data.self) == exactBytes)
        let grants = try await reopenedSQL.raw("SELECT study_id FROM study_data_grants").all()
        #expect(grants.count == (withdrawFirstStudy ? 1 : 2))
        let studies = try Set(grants.map { try $0.decode(column: "study_id", as: UUID.self) })
        #expect(studies.contains(prepared.studyIDs[1]))
        #expect(studies.contains(prepared.studyIDs[0]) == !withdrawFirstStudy)
        let checkpoint = try #require(try await reopenedSQL.raw("SELECT status, accepted_through FROM provider_checkpoints").first())
        #expect(try checkpoint.decode(column: "status", as: String.self) == "complete")
        #expect(try checkpoint.decode(column: "accepted_through", as: Date?.self) != nil)
        let audit = try #require(try await reopenedSQL.raw("""
            SELECT actor_subject, initiator_subject FROM audit_events WHERE action = 'clinical.event.accepted'
            """).first())
        #expect(try audit.decode(column: "actor_subject", as: String.self) == "provider-worker")
        #expect(try audit.decode(column: "initiator_subject", as: String.self) == ClinicalEventStoreTests.participant.subject)
    }

}
