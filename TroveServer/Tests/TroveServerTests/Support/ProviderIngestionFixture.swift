//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import GroveFHIRContract
import Testing
import TroveAPITypes
@testable import TroveServer
import Vapor


enum ProviderIngestionFixture {
    struct Prepared: Sendable {
        let connection: ProviderConnectionService.Status
        let enrollmentIDs: [UUID]
        let studyIDs: [UUID]
        let vault: ProviderCredentialVault
    }

    actor Upstream {
        let measuredAt: Date
        let recordCount: Int
        var requests = 0

        init(measuredAt: Date, recordCount: Int = 1) {
            self.measuredAt = measuredAt
            self.recordCount = recordCount
        }

        func reply(endpoint: ProviderHTTPTransport.Endpoint, bearer: String?) throws -> Data {
            #expect(endpoint == .withingsMeasures)
            #expect(bearer == "synthetic-access")
            requests += 1
            return try JSONSerialization.data(withJSONObject: [
                "status": 0,
                "body": [
                    "timezone": "UTC",
                    "more": 0,
                    "measuregrps": (0..<recordCount).map { index in
                        [
                            "grpid": 12345 + index, "attrib": 0, "category": 1,
                            "date": Int64(measuredAt.timeIntervalSince1970),
                            "measures": [["type": 1, "value": 725, "unit": -1]]
                        ] as [String: Any]
                    }
                ]
            ])
        }
    }

    actor ValidationInterruption {
        private var calls = 0
        func check() throws {
            calls += 1
            // Staging validates first; interruption occurs before the first custody write.
            if calls == 2 { throw CancellationError() }
        }
    }

    static func prepare(
        on app: Application,
        authorization: ProviderFixture.Authorization,
        profile: CollectionObservationProfile = .bodyWeight,
        sourceToken: String = "getmeas:1",
        registration: ProviderRegistration? = nil
    ) async throws -> Prepared {
        try await ParticipantFixtures.createParticipant(on: app.db)
        let group = try await GroupFixtures.createGroup(on: app.db)
        let registration = try registration ?? ProviderFixture.registration()
        try await ProviderRegistrationStore(database: app.db).configure(
            registration, approved: true, audit: ClinicalEventStoreTests.researcher.auditContext
        )
        let studyIDs = try await AuthContext.$current.withValue(ClinicalEventStoreTests.researcher) {
            var ids: [UUID] = []
            for _ in 0..<2 {
                let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
                study.consent[.enUS] = ConsentContent(title: "Consent", content: "<toggle id=\"agree\" expected-value=\"true\">I agree.</toggle>")
                study.collectionRequirements = [
                    .init(
                        profile: profile.rawValue,
                        sourceKind: .serverWorker,
                        measurementWindow: .init(
                            calendar: .gregorian, timeZone: "UTC", start: .absolute(.init(_type: .absolute, date: Date().addingTimeInterval(-3600)))
                        ),
                        providerRegistrationID: registration.id,
                        sourceTypeIdentifier: sourceToken
                    )
                ]
                try await study.save(on: app.db)
                try await PublishedStudyFixtures.createNextClinicalRevision(on: app.db, studyId: study.requireId())
                ids.append(try study.requireId())
            }
            return ids
        }
        let service = try ProviderFixture.service(on: app, authorization: authorization)
        return try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            var enrollmentIDs: [UUID] = []
            for studyID in studyIDs {
                let enrollment = try await app.grove[ParticipantEnrollmentService.self].enroll(studyId: studyID, invitationCode: nil)
                let id = try enrollment.requireID()
                _ = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: id, on: app)
                enrollmentIDs.append(id)
            }
            let intent = try await service.start(registrationID: registration.id, redirectID: "native")
            let connection = try await service.complete(id: intent.id, state: ProviderFixture.state(intent), code: "synthetic-code")
            return Prepared(connection: connection, enrollmentIDs: enrollmentIDs, studyIDs: studyIDs, vault: service.vault)
        }
    }

    static func worker(
        on app: Application,
        prepared: Prepared,
        authorization: ProviderFixture.Authorization,
        upstream: Upstream,
        validator: FHIRValidationClient
    ) throws -> ProviderIngestionService {
        try .init(
            database: app.db,
            validator: validator,
            credentialService: .init(database: app.db, vault: prepared.vault, authorization: authorization),
            keyring: TestApp.sourceKeyring(),
            worker: .init(issuer: "https://example.test/workers", clientID: "provider-worker", applicationRevision: "synthetic-revision"),
            facts: .init(
                application: .init(name: "Trove", bundleIdentifier: "org.example.Trove", version: "1"),
                host: .init(operatingSystemName: "Linux", operatingSystemVersion: "6")
            ),
            limits: .standard,
            client: WithingsMeasurementClient(
                transport: .init { endpoint, _, bearer, _ in try await upstream.reply(endpoint: endpoint, bearer: bearer) },
                limits: .standard
            )
        )
    }
}
