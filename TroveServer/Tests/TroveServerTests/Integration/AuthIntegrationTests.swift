//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveHealthKit
import GroveLocalization
import JWTKit
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


@Suite(.serialized)
struct AuthIntegrationTests {
    @Test
    func unauthenticatedReturns401() async throws {
        try await withFixtures(token: .none) { app, token, endpoints in
            for endpoint in endpoints {
                try await self.expectStatus(.unauthorized, for: endpoint, token: token, on: app)
            }
        }
    }

    @Test
    func expiredTokenReturns401() async throws {
        try await TestApp.withApp(token: .none) { app, _ in
            let keys = JWTKeyCollection()
            await keys.add(hmac: HMACKey(from: TestApp.testSecret), digestAlgorithm: .sha256)

            let expiredToken = try await TestApp.signToken(
                keys: keys,
                roles: [TestApp.researcherRole],
                groups: ["/Test Group/admin"],
                expiration: Date().addingTimeInterval(-60)
            )

            try await app.test(.GET, "\(apiBasePath)/groups", beforeRequest: { req in
                req.bearerAuth(expiredToken)
            }) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func wrongSignatureReturns401() async throws {
        try await TestApp.withApp(token: .none) { app, _ in
            let wrongKeys = JWTKeyCollection()
            await wrongKeys.add(hmac: HMACKey(from: TestApp.wrongTestSecret), digestAlgorithm: .sha256)

            let badToken = try await TestApp.signToken(
                keys: wrongKeys,
                roles: [TestApp.researcherRole],
                groups: ["/Test Group/admin"]
            )

            try await app.test(.GET, "\(apiBasePath)/groups", beforeRequest: { req in
                req.bearerAuth(badToken)
            }) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func wrongGroupReturns403() async throws {
        try await withFixtures(token: .researcher(groups: ["/Other Group/admin"])) { app, token, endpoints in
            for endpoint in endpoints where endpoint.requiresGroupAccess {
                try await self.expectStatus(.forbidden, for: endpoint, token: token, on: app)
            }
        }
    }

    @Test
    func researcherDeniedAdminActions() async throws {
        try await withFixtures(token: .researcher(groups: ["/Test Group/researcher"])) { app, token, endpoints in
            for endpoint in endpoints where endpoint.requiresGroupAccess && endpoint.minRole > .researcher {
                try await self.expectStatus(.forbidden, for: endpoint, token: token, on: app)
            }
        }
    }

    @Test
    func researcherAllowedActions() async throws {
        let endpoints = Self.allEndpoints(.dummy)
        for index in endpoints.indices where endpoints[index].requiresGroupAccess && endpoints[index].minRole <= .researcher {
            try await withFixtures(token: .researcher(groups: ["/Test Group/researcher"])) { app, token, endpoints in
                let endpoint = endpoints[index]
                try await self.expectStatus(endpoint.successStatus, for: endpoint, token: token, on: app)
            }
        }
    }

    @Test
    func adminAllowedActions() async throws {
        let endpoints = Self.allEndpoints(.dummy)
        for index in endpoints.indices {
            let endpoint = endpoints[index]
            guard endpoint.requiresGroupAccess, endpoint.minRole == .admin, !endpoint.requiresAuditReader else { continue }
            try await withFixtures(token: .researcher(), preparePublication: true) { app, token, endpoints in
                let endpoint = endpoints[index]
                try await self.expectStatus(endpoint.successStatus, for: endpoint, token: token, on: app)
            }
        }
    }

    @Test(arguments: [
        (["/Test Group/admin"], HTTPStatus.forbidden),
        (["/Test Group/admin", "/Test Group/audit-reader"], HTTPStatus.ok),
        (["/Test Group/admin", "/Test Group/researcher", "/Test Group/audit-reader"], HTTPStatus.ok),
        (["/Test Group/audit-reader", "/Test Group/researcher", "/Test Group/admin"], HTTPStatus.ok)
    ])
    func auditReadersRequireExplicitCapability(groups: [String], expected: HTTPStatus) async throws {
        try await withFixtures(token: .researcher(groups: groups)) { app, token, endpoints in
            for endpoint in endpoints where endpoint.requiresAuditReader {
                try await self.expectStatus(expected, for: endpoint, token: token, on: app)
            }
        }
    }

    @Test
    func participantDeniedResearcherEndpoints() async throws {
        try await TestApp.withApp(token: .participant(subject: "participant-test-user")) { app, token in
            let endpoints = Self.allEndpoints(.dummy)

            for endpoint in endpoints where !endpoint.isParticipant {
                try await self.expectStatus(.forbidden, for: endpoint, token: token, on: app)
            }
        }
    }

    @Test
    func researcherDeniedParticipantEndpoints() async throws {
        try await TestApp.withApp { app, token in
            let endpoints = Self.allEndpoints(.dummy)

            for endpoint in endpoints where endpoint.isParticipant {
                try await self.expectStatus(.forbidden, for: endpoint, token: token, on: app)
            }
        }
    }

    @Test
    func participantAllowedActions() async throws {
        try await withFixtures(token: .participant(subject: "participant-test-user")) { app, token, endpoints in
            for endpoint in endpoints where endpoint.isParticipant {
                try await self.expectStatus(endpoint.successStatus, for: endpoint, token: token, on: app)
            }
        }
    }

    @Test
    func allAPIEndpointsCoveredByAuthTests() async throws {
        try await TestApp.withApp { app, _ in
            let registeredRoutes = Self.normalizedRoutes(from: app)
            let testedRoutes = Self.normalizedTestedRoutes()

            let missing = registeredRoutes.subtracting(testedRoutes)
            let extra = testedRoutes.subtracting(registeredRoutes)

            #expect(missing.isEmpty, "Routes missing from auth tests: \(missing.sorted())")
            #expect(extra.isEmpty, "Auth tests reference non-existent routes: \(extra.sorted())")
        }
    }

    // MARK: - Instance Helpers

    private func withFixtures(
        token tokenConfig: TestApp.Token,
        preparePublication: Bool = false,
        _ test: @escaping @Sendable (Application, String?, [AuthEndpoint]) async throws -> Void
    ) async throws {
        try await TestApp.withApp(token: tokenConfig, validator: Self.validator, grantorAuthority: Self.authority) { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let groupId = try group.requireId()
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: groupId)
            let studyId = try study.requireId()
            let healthData = try await ComponentFixtures.createHealthDataComponent(on: app.db, studyId: studyId)
            let healthDataId = try healthData.requireId()
            let informational = try await ComponentFixtures.createInformationalComponent(on: app.db, studyId: studyId)
            let informationalId = try informational.requireId()
            let questionnaire = try await ComponentFixtures.createQuestionnaireComponent(on: app.db, studyId: studyId)
            let questionnaireId = try questionnaire.requireId()
            let schedule = try await ComponentFixtures.createSchedule(on: app.db, componentId: questionnaireId)
            let scheduleId = try schedule.requireId()
            let validationID: UUID
            if preparePublication {
                // Keep the retained-study deletion control independent of endpoint execution order.
                try await PublishedStudyFixtures.createPublishedStudy(on: app.db, studyId: studyId)
                let response = try await PublicationWorkflowFixtures.validate(studyId, app: app, token: token)
                try #require(response.status == .created)
                validationID = try #require(UUID(uuidString: response.content.decode(Components.Schemas.StudyDraftValidation.self).id))
            } else {
                validationID = UUID()
            }

            if case .participant(let subject, _) = tokenConfig {
                try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: subject)
            }

            let ids = FixtureIDs(
                groupId: groupId,
                studyId: studyId,
                healthDataId: healthDataId,
                informationalId: informationalId,
                questionnaireId: questionnaireId,
                scheduleId: scheduleId,
                draftRevision: study.draftRevision,
                validationID: validationID
            )
            try await test(app, token, Self.allEndpoints(ids))
        }
    }

    private func expectStatus(
        _ expected: HTTPStatus,
        for endpoint: AuthEndpoint,
        token: String?,
        on app: Application
    ) async throws {
        try await app.test(endpoint.method, endpoint.path, beforeRequest: { req in
            req.bearerAuth(token)
            if let ifMatch = endpoint.ifMatch {
                req.headers.replaceOrAdd(name: "If-Match", value: ifMatch)
            }
            if endpoint.method == .POST, endpoint.path.hasSuffix("/consents") {
                req.headers.replaceOrAdd(name: "Idempotency-Key", value: UUID().uuidString)
                req.headers.replaceOrAdd(name: "If-Match", value: EnrollmentStateTag.make(enrollmentID: dummyUUID, version: 1))
            }
            if let body = endpoint.body {
                if let contentType = endpoint.contentType {
                    req.headers.contentType = contentType
                }
                req.body = .init(data: body)
            }
        }) { response in
            #expect(response.status == expected, "Expected \(expected.code) for \(endpoint.method.rawValue) \(endpoint.path), got \(response.status.code)")
        }
    }
}
