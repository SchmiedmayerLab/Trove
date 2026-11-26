//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit
import Testing
import TroveAPITypes
@testable import TroveServer
import VaporTesting


struct CollectionRouteAvailabilityTests {
    private static func service(on app: Application, registrationID: UUID) -> ProviderRegistrationService {
        .init(
            database: app.db,
            clients: [WithingsMeasurementClient(transport: .init { _, _, _, _ in throw ProviderFailure.unavailable }, limits: .standard)],
            registrationIDs: [registrationID],
            authorization: app.grove[AuthorizationService.self],
            studies: app.grove[StudyRepository.self]
        )
    }

    private static func setApproval(_ approved: Bool, for registration: ProviderRegistration, on app: Application) async throws {
        try await ProviderRegistrationStore(database: app.db).configure(
            registration, approved: approved, audit: ClinicalEventStoreTests.researcher.auditContext
        )
    }

    @Test
    func unreadableProviderConfigurationFailsOptionalRouteAssessment() async throws {
        try await TestApp.withApp { app, _ in
            let registration = try ProviderFixture.registration()
            try await Self.setApproval(true, for: registration, on: app)
            let sql = try ProviderSQL.sql(app.db)
            try await sql.raw("UPDATE provider_registrations SET configuration = '{}' WHERE id = \(bind: registration.id)").run()
            let service = Self.service(on: app, registrationID: registration.id)
            let optional = CollectionRequirement(
                profile: CollectionObservationProfile.bodyWeight.rawValue,
                sourceKind: .serverWorker,
                providerRegistrationID: registration.id,
                sourceTypeIdentifier: "getmeas:1",
                requirement: .optional
            )
            await #expect(throws: ProviderFailure.unavailable) {
                try await app.db.transaction { try await service.routes(for: [optional], on: $0) }
            }
        }
    }

    @Test
    func providerRoutesAreAvailableOnlyThroughAnApprovedQualifyingRegistration() async throws {
        try await TestApp.withApp { app, _ in
            let registration = try ProviderFixture.registration()
            try await Self.setApproval(true, for: registration, on: app)
            let service = Self.service(on: app, registrationID: registration.id)
            let qualified = CollectionRequirement(
                profile: CollectionObservationProfile.bodyWeight.rawValue,
                sourceKind: .serverWorker,
                providerRegistrationID: registration.id,
                sourceTypeIdentifier: "getmeas:1"
            )
            let otherProfile = CollectionRequirement(
                profile: CollectionObservationProfile.heartRate.rawValue,
                sourceKind: .serverWorker,
                providerRegistrationID: registration.id,
                sourceTypeIdentifier: "getmeas:1",
                requirement: .optional
            )
            let unknownRegistration = CollectionRequirement(
                profile: CollectionObservationProfile.bodyWeight.rawValue,
                sourceKind: .serverWorker,
                providerRegistrationID: UUID(),
                sourceTypeIdentifier: "getmeas:1"
            )
            let native = CollectionRequirement(profile: CollectionObservationProfile.heartRate.rawValue, sourceKind: .participantApp)
            let requirements = [qualified, otherProfile, unknownRegistration, native]
            let routes = try await app.db.transaction { try await service.routes(for: requirements, on: $0) }
            #expect(routes.map(\.available) == [true, false, false, true])
            #expect(routes.map(\.index) == [0, 1, 2, 3])
            #expect(routes.map { $0.diagnostic?.rule } == [nil, "route-optional-unavailable", "route-unavailable", nil])
            #expect(routes[1].diagnostic?.severity == .warning && routes[2].diagnostic?.severity == .error)

            try await Self.setApproval(false, for: registration, on: app)
            let withdrawn = try await app.db.transaction { try await service.routes(for: [qualified], on: $0) }
            #expect(withdrawn.map(\.available) == [false])
            await #expect(throws: AuditError.transactionRequired) { try await service.routes(for: [qualified], on: app.db) }
        }
    }
}
