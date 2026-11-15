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
import TroveAPITypes
@testable import TroveServer
import Vapor


enum ProviderRetainedFixture {
    struct Collected: Sendable {
        let prepared: ProviderIngestionFixture.Prepared
        let authorization: ProviderFixture.Authorization
        let upstream: ProviderIngestionFixture.Upstream
        let worker: ProviderIngestionService
    }

    struct Consent: Sendable {
        let studyID: UUID
        let enrollmentID: UUID
    }

    static func collect(on app: Application, recordCount: Int = 1) async throws -> Collected {
        let authorization = ProviderFixture.Authorization()
        let prepared = try await ProviderIngestionFixture.prepare(on: app, authorization: authorization)
        let upstream = ProviderIngestionFixture.Upstream(measuredAt: Date().addingTimeInterval(-30), recordCount: recordCount)
        let worker = try ProviderIngestionFixture.worker(
            on: app, prepared: prepared, authorization: authorization, upstream: upstream, validator: ClinicalEventBatchTests.validator()
        )
        #expect(try await worker.run(connectionID: prepared.connection.id, sourceToken: "getmeas:1"))
        return Collected(prepared: prepared, authorization: authorization, upstream: upstream, worker: worker)
    }

    static func addStudy(
        on app: Application, prepared: ProviderIngestionFixture.Prepared, registrationID: UUID
    ) async throws -> Consent {
        let original = try #require(try await Study.find(prepared.studyIDs[0], on: app.db))
        let studyID = try await AuthContext.$current.withValue(ClinicalEventStoreTests.researcher) {
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: original.$group.id)
            study.consent = original.consent
            study.collectionRequirements = [
                .init(
                    profile: CollectionObservationProfile.bodyWeight.rawValue,
                    sourceKind: .serverWorker,
                    measurementWindow: .init(
                        calendar: .gregorian,
                        timeZone: "UTC",
                        start: .absolute(.init(_type: .absolute, date: Date().addingTimeInterval(-3600)))
                    ),
                    providerRegistrationID: registrationID,
                    sourceTypeIdentifier: "getmeas:1"
                )
            ]
            try await study.save(on: app.db)
            try await PublishedStudyFixtures.createNextClinicalRevision(on: app.db, studyId: study.requireId())
            return try study.requireId()
        }
        return try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            let enrollment = try await app.grove[ParticipantEnrollmentService.self].enroll(studyId: studyID, invitationCode: nil)
            let enrollmentID = try enrollment.requireID()
            _ = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: enrollmentID, on: app)
            return Consent(studyID: studyID, enrollmentID: enrollmentID)
        }
    }

    static func newConnection(
        on app: Application, authorization: ProviderFixture.Authorization
    ) async throws -> ProviderConnectionService.Status {
        let registration = try ProviderFixture.registration()
        try await ProviderRegistrationStore(database: app.db).configure(
            registration, approved: true, audit: ClinicalEventStoreTests.researcher.auditContext
        )
        let service = try ProviderFixture.service(on: app, authorization: authorization)
        return try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            let intent = try await service.start(registrationID: registration.id, redirectID: "native")
            return try await service.complete(id: intent.id, state: ProviderFixture.state(intent), code: "synthetic-second-code")
        }
    }

    static func retireCredentials(connectionID: UUID, on app: Application) async throws {
        try await ProviderSQL.sql(app.db)
            .raw("""
                UPDATE provider_connections SET status = 'reauthorization-required', refresh_state = 'uncertain', credential_envelope = NULL
                WHERE id = \(bind: connectionID)
                """)
            .run()
    }

    static func recordBytes(on app: Application) async throws -> Data {
        let row = try #require(try await ProviderSQL.sql(app.db).raw("SELECT raw_bytes FROM clinical_events").first())
        return try row.decode(column: "raw_bytes", as: Data.self)
    }

    static func count(_ table: String, on app: Application) async throws -> Int {
        let row = try #require(try await ProviderSQL.sql(app.db).raw("SELECT COUNT(*) AS count FROM \(ident: table)").first())
        return try row.decode(column: "count", as: Int.self)
    }
}
