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


struct ProviderRegistrationTests {
    private static func service(on app: Application, registrationID: UUID) -> ProviderRegistrationService {
        .init(
            database: app.db,
            clients: [WithingsMeasurementClient(transport: .init { _, _, _, _ in throw ProviderFailure.unavailable }, limits: .standard)],
            registrationIDs: [registrationID],
            authorization: app.grove[AuthorizationService.self],
            studies: app.grove[StudyRepository.self]
        )
    }

    @Test
    func configuredAcquisitionAndStudyEditAuthorityBoundCapabilityDisclosure() async throws {
        try await TestApp.withApp { app, _ in
            try await ParticipantFixtures.createParticipant(on: app.db)
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let enabled = try ProviderFixture.registration(), unconfigured = try ProviderFixture.registration()
            for registration in [enabled, unconfigured] {
                try await ProviderRegistrationStore(database: app.db).configure(
                    registration, approved: true, audit: ClinicalEventStoreTests.researcher.auditContext
                )
            }
            let service = Self.service(on: app, registrationID: enabled.id)
            let available = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await service.registrations()
            }
            #expect(available.map(\.id) == [enabled.id])
            #expect(Set(available.flatMap(\.capabilities).map(\.sourceTypeIdentifier)) == enabled.sourceTokens)
            let authored = try await AuthContext.$current.withValue(ClinicalEventStoreTests.researcher) {
                try await service.registrations(studyID: study.requireId())
            }
            #expect(authored.map(\.id) == [enabled.id])
            await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                await #expect(throws: (any Error).self) { try await service.registrations(studyID: study.requireId()) }
            }
            let rows = try await ProviderSQL.sql(app.db)
                .raw("""
                    SELECT action FROM audit_events WHERE action IN ('provider.registration.disclosure', 'study.draft.disclosure')
                    """)
                .all()
            #expect(rows.count == 2)
        }
    }

    @Test
    func publicationRequiresTheExactApprovedQualifiedRegistrationTokenAndProfile() async throws {
        try await TestApp.withApp { app, _ in
            let registration = try ProviderFixture.registration()
            try await ProviderRegistrationStore(database: app.db).configure(
                registration, approved: true, audit: ClinicalEventStoreTests.researcher.auditContext
            )
            let service = Self.service(on: app, registrationID: registration.id)
            let allowed = CollectionRequirement(
                profile: CollectionObservationProfile.bodyWeight.rawValue,
                sourceKind: .serverWorker,
                providerRegistrationID: registration.id,
                sourceTypeIdentifier: "getmeas:1"
            )
            try await app.db.transaction { try await service.validate(requirements: [allowed], on: $0) }
            let mismatched = CollectionRequirement(
                profile: CollectionObservationProfile.heartRate.rawValue,
                sourceKind: .serverWorker,
                providerRegistrationID: registration.id,
                sourceTypeIdentifier: "getmeas:1"
            )
            await #expect {
                try await app.db.transaction { try await service.validate(requirements: [mismatched], on: $0) }
            } throws: { ($0 as? ServerError)?.status.code == 409 }
            try await ProviderRegistrationStore(database: app.db).configure(
                registration, approved: false, audit: ClinicalEventStoreTests.researcher.auditContext
            )
            await #expect {
                try await app.db.transaction { try await service.validate(requirements: [allowed], on: $0) }
            } throws: { ($0 as? ServerError)?.status.code == 409 }
        }
    }
}
