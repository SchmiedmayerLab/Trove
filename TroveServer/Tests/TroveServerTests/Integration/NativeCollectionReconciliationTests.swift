//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import GroveHealthKit
import SQLKit
import Testing
import TroveAPIClient
import TroveAPIServer
@testable import TroveServer
import VaporTesting


struct NativeCollectionReconciliationTests {
    private typealias Instruction = Components.Schemas.NativeCollectionReconciliationInstruction
    private typealias Fixture = ClinicalEventStoreTests.Fixture

    @Test
    func endedSleepWindowYieldsOneRenewableInstructionThatCompletesOnce() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, profile: CollectionObservationProfile.sleepStage.rawValue)
            #expect(try await Self.request(fixture, on: app, token: token).isEmpty, "An ongoing enrollment has no closed window")
            let end = try await Self.end(fixture.enrollmentIDs[0], on: app)
            let plan = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await app.grove[ConsentService.self].collectionPlan(enrollmentID: fixture.enrollmentIDs[0])
            }
            let first = try #require(try await Self.request(fixture, on: app, token: token).first)
            #expect(first.sourceId == fixture.source.id.uuidString.lowercased())
            #expect(first.profile == CollectionObservationProfile.sleepStage.rawValue && !first.includeWorkoutRoutes)
            #expect(first.sourceTypeIdentifier == CollectionObservationProfile.sleepStage.nativeSourceTypeIdentifier)
            #expect(first.end == end && first.start == plan.windows[0].requirements[0].start && first.end <= first.issuedAt)
            #expect(first.expiresAt.timeIntervalSince(first.issuedAt) == NativeReconciliationSettings.defaultLeaseDuration)
            // The installation accepts exactly what the server issued against the plan it already retains.
            let id = try #require(UUID(uuidString: first.id))
            let authority = try NativeCollectionReconciliation(first, plan: plan, sourceID: fixture.source.id, at: first.issuedAt)
            #expect(authority.id == id && authority.definition.stream == .sleepStage)

            let renewed = try #require(try await Self.request(fixture, on: app, token: token).first)
            #expect(renewed.id == first.id && renewed.start == first.start && renewed.end == first.end)
            #expect(renewed.issuedAt >= first.issuedAt && renewed.expiresAt >= first.expiresAt)
            #expect(try NativeCollectionReconciliation(renewed, plan: plan, sourceID: fixture.source.id, at: renewed.issuedAt).renews(authority))

            for _ in 0..<2 {
                try await Self.complete(id, fixture, on: app, token: token, expecting: .noContent)
            }
            #expect(try await Self.request(fixture, on: app, token: token).isEmpty)
            #expect(try await Self.count("native_collection_reconciliations", on: app) == 1)
            #expect(try await Self.audits("collection.reconciliation.completed", on: app) == 2)
            #expect(try await Self.audits("collection.reconciliation.issued", on: app) == 4)
        }
    }

    @Test(arguments: [false, true])
    func workoutRouteSweepExistsOnlyForTheAcceptedRouteOption(routes: Bool) async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(
                on: app, profile: CollectionObservationProfile.workout.rawValue, routeStudies: routes ? [0] : []
            )
            _ = try await Self.end(fixture.enrollmentIDs[0], on: app)
            let instructions = try await Self.request(fixture, on: app, token: token)
            let workout = CollectionObservationProfile.workout
            var expected = [[workout.rawValue, try #require(workout.nativeSourceTypeIdentifier)]]
            if routes {
                expected.append([CollectionObservationProfile.healthKitRecording.rawValue, SampleType.workoutRoute.hkSampleType.identifier])
            }
            #expect(instructions.map { [$0.profile, $0.sourceTypeIdentifier] } == expected)
            #expect(instructions.allSatisfy { $0.includeWorkoutRoutes == routes } && Set(instructions.map(\.id)).count == expected.count)
        }
    }

    @Test
    func heartRateWindowsAndWithdrawnEnrollmentsAreNeverSwept() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let points = try await ClinicalEventStoreTests.prepare(on: app)
            _ = try await Self.end(points.enrollmentIDs[0], on: app)
            #expect(try await Self.request(points, on: app, token: token).isEmpty)
        }
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, profile: CollectionObservationProfile.sleepStage.rawValue)
            _ = try await Self.end(fixture.enrollmentIDs[0], on: app)
            let issued = try #require(try await Self.request(fixture, on: app, token: token).first)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: fixture.enrollmentIDs[0])
            }
            #expect(try await Self.request(fixture, on: app, token: token).isEmpty)
            let stored = try await Self.instruction(on: app)
            #expect(stored.id == issued.id && stored.expiresAt == issued.expiresAt, "Withdrawal must not renew a lease")
        }
    }

    @Test(arguments: [(TestApp.Token.none, 401), (.researcher(), 403), (.participant(subject: "other-participant"), 404)])
    func onlyTheAuthenticatedOwnerCanRequestOrComplete(identity: TestApp.Token, status: Int) async throws {
        try await TestApp.withApp(token: identity) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, profile: CollectionObservationProfile.sleepStage.rawValue)
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: "other-participant")
            _ = try await Self.end(fixture.enrollmentIDs[0], on: app)
            for path in [Self.path(fixture), Self.path(fixture) + "/\(UUID())/complete"] {
                try await app.test(.POST, path, beforeRequest: { try Self.prepare(&$0, fixture, token: token) }) { response in
                    #expect(Int(response.status.code) == status)
                }
            }
            #expect(try await Self.count("native_collection_reconciliations", on: app) == 0)
            #expect(try await Self.audits("collection.reconciliation.issued", on: app) == 0)
        }
    }

    @Test(arguments: ["unknown-installation", "revoked-installation", "foreign-source", "unknown-sweep"])
    func installationProofAndExactSweepAreRequired(mode: String) async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, profile: CollectionObservationProfile.sleepStage.rawValue)
            _ = try await Self.end(fixture.enrollmentIDs[0], on: app)
            let issued = try #require(try await Self.request(fixture, on: app, token: token).first)
            var installation = fixture.installationID, sourceID = fixture.source.id, sweep = try #require(UUID(uuidString: issued.id))
            switch mode {
            case "unknown-installation": installation = UUID()
            case "revoked-installation":
                try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                    _ = try await app.grove[SourceInstallationService.self].revoke(registrationID: fixture.installationID)
                }
            case "foreign-source": sourceID = UUID()
            default: sweep = UUID()
            }
            let expected: HTTPStatus = switch mode {
            case "unknown-installation": .forbidden
            case "revoked-installation": .conflict
            default: .notFound
            }
            let paths = mode == "unknown-sweep" ? [] : [Self.path(fixture)]
            for path in paths + [Self.path(fixture) + "/\(sweep)/complete"] {
                try await app.test(.POST, path, beforeRequest: {
                    $0.bearerAuth(token)
                    $0.sourceInstallation(installation)
                    try $0.encodeJSONBody(Components.Schemas.NativeCollectionReconciliationRequest(sourceId: sourceID.uuidString))
                }) { response in
                    #expect(response.status == expected)
                }
            }
            let stored = try await Self.instruction(on: app)
            #expect(stored.expiresAt == issued.expiresAt)
            #expect(try await Self.audits("collection.reconciliation.completed", on: app) == 0)
            #expect(try await Self.audits("collection.reconciliation.issued", on: app) == 1)
        }
    }

    @Test
    func leaseDurationIsConfigurableAndRejectsUnusableValues() throws {
        #expect(try NativeReconciliationSettings(seconds: nil).leaseDuration == 900)
        #expect(try NativeReconciliationSettings(seconds: "120").leaseDuration == 120)
        for value in ["0", "-1", "nan", "inf", "soon", ""] {
            #expect(throws: NativeReconciliationSettings.ConfigurationError.invalidLeaseDuration) {
                try NativeReconciliationSettings(seconds: value)
            }
        }
    }
}


extension NativeCollectionReconciliationTests {
    private static func path(_ fixture: Fixture) -> String {
        "\(apiBasePath)/participant/enrollments/\(fixture.enrollmentIDs[0])/collection-reconciliations"
    }

    private static func prepare(_ request: inout TestingHTTPRequest, _ fixture: Fixture, token: String?) throws {
        request.bearerAuth(token)
        request.sourceInstallation(fixture.installationID)
        try request.encodeJSONBody(Components.Schemas.NativeCollectionReconciliationRequest(sourceId: fixture.source.id.uuidString))
    }

    private static func end(_ enrollmentID: UUID, on app: Application) async throws -> Date {
        let enrollment = try #require(try await Enrollment.find(enrollmentID, on: app.db))
        enrollment.endsAt = Date()
        try await enrollment.save(on: app.db)
        return try #require(try await Enrollment.find(enrollmentID, on: app.db)?.endsAt)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { try TroveDateTranscoder().decode($0.singleValueContainer().decode(String.self)) }
        return decoder
    }

    private static func request(_ fixture: Fixture, on app: Application, token: String?) async throws -> [Instruction] {
        var reply: Components.Schemas.NativeCollectionReconciliationResponse?
        try await app.test(.POST, path(fixture), beforeRequest: { try prepare(&$0, fixture, token: token) }) { response in
            try #require(response.status == .ok)
            #expect(response.headers.first(name: "Cache-Control") == "no-store")
            reply = try decoder().decode(
                Components.Schemas.NativeCollectionReconciliationResponse.self, from: Data(response.body.readableBytesView)
            )
        }
        return try #require(reply).instructions
    }

    private static func complete(_ id: UUID, _ fixture: Fixture, on app: Application, token: String?, expecting status: HTTPStatus) async throws {
        try await app.test(.POST, path(fixture) + "/\(id)/complete", beforeRequest: { try prepare(&$0, fixture, token: token) }) { response in
            #expect(response.status == status)
            #expect(response.headers.first(name: "Cache-Control") == "no-store")
        }
    }

    private static func sql(_ app: Application) throws -> any SQLDatabase { try #require(app.db as? any SQLDatabase) }

    private static func count(_ table: String, on app: Application) async throws -> Int {
        let row = try #require(try await sql(app).raw("SELECT count(*) AS count FROM \(ident: table)").first())
        return try row.decode(column: "count", as: Int.self)
    }

    private static func audits(_ action: String, on app: Application) async throws -> Int {
        let row = try #require(try await sql(app).raw("SELECT count(*) AS count FROM audit_events WHERE action = \(bind: action)").first())
        return try row.decode(column: "count", as: Int.self)
    }

    private static func instruction(on app: Application) async throws -> Instruction {
        let row = try #require(try await sql(app).raw("SELECT instruction FROM native_collection_reconciliations").first())
        return try decoder().decode(Instruction.self, from: Data(row.decode(column: "instruction", as: String.self).utf8))
    }
}
