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


private let dummyUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
private let dummyRevision = "99999"

private struct FixtureIDs: Sendable {
    static let dummy = FixtureIDs(
        groupId: dummyUUID,
        studyId: dummyUUID,
        healthDataId: dummyUUID,
        informationalId: dummyUUID,
        questionnaireId: dummyUUID,
        scheduleId: dummyUUID
    )

    let groupId: UUID
    let studyId: UUID
    let healthDataId: UUID
    let informationalId: UUID
    let questionnaireId: UUID
    let scheduleId: UUID
}

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
        try await withFixtures(token: .researcher(groups: ["/Test Group/researcher"])) { app, token, endpoints in
            for endpoint in endpoints where endpoint.requiresGroupAccess && endpoint.minRole <= .researcher {
                try await self.expectStatus(endpoint.successStatus, for: endpoint, token: token, on: app)
            }
        }
    }

    @Test
    func adminAllowedActions() async throws {
        try await withFixtures(token: .researcher(groups: ["/Test Group/admin"])) { app, token, endpoints in
            for endpoint in endpoints where endpoint.requiresGroupAccess && endpoint.minRole == .admin && !endpoint.requiresAuditReader {
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
        _ test: @escaping @Sendable (Application, String?, [AuthEndpoint]) async throws -> Void
    ) async throws {
        try await TestApp.withApp(token: tokenConfig) { app, token in
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

            if case .participant(let subject, _) = tokenConfig {
                try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: subject)
            }

            let ids = FixtureIDs(
                groupId: groupId,
                studyId: studyId,
                healthDataId: healthDataId,
                informationalId: informationalId,
                questionnaireId: questionnaireId,
                scheduleId: scheduleId
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


// MARK: - Static Helpers

extension AuthIntegrationTests {
    private static func researcher(
        _ method: HTTPMethod,
        _ path: String,
        body: Data? = nil,
        minRole: AuthContext.GroupRole = .researcher, // swiftlint:disable:this function_default_parameter_at_end
        successStatus: HTTPStatus,
        requiresGroupAccess: Bool = true
    ) -> AuthEndpoint {
        AuthEndpoint(
            method: method,
            path: path,
            body: body,
            contentType: body != nil ? .json : nil,
            role: .researcher(minRole: minRole, requiresGroupAccess: requiresGroupAccess),
            successStatus: successStatus
        )
    }

    private static func participant(
        _ method: HTTPMethod,
        _ path: String,
        successStatus: HTTPStatus,
        body: Data? = nil,
        contentType: HTTPMediaType? = nil
    ) -> AuthEndpoint {
        AuthEndpoint(
            method: method,
            path: path,
            body: body,
            contentType: contentType ?? (body != nil ? .json : nil),
            role: .participant,
            successStatus: successStatus
        )
    }

    // swiftlint:disable:next function_body_length
    private static func allEndpoints(_ ids: FixtureIDs) -> [AuthEndpoint] {
        let groupId = ids.groupId
        let studyId = ids.studyId
        let healthDataId = ids.healthDataId
        let informationalId = ids.informationalId
        let questionnaireId = ids.questionnaireId
        let scheduleId = ids.scheduleId
        let informational = jsonData(Components.Schemas.InformationalComponentInput(
            name: "X",
            data: .init([.enUS: InformationalContent(title: "T", content: "C")])
        ))
        let questionnaire = jsonData(Components.Schemas.QuestionnaireComponentInput(
            name: "X",
            data: .init([.enUS: QuestionnaireContent(questionnaire: "{}")])
        ))
        let healthData = jsonData(Components.Schemas.HealthDataComponentInput(
            name: "X",
            data: .init(sampleTypes: [.quantity(.heartRate)], historicalDataCollection: .init())
        ))
        let scheduleBody = jsonData(scheduleBody())
        let dummyId = dummyUUID
        let base = apiBasePath

        return [
            // Groups
            researcher(.GET, "\(base)/groups", successStatus: .ok, requiresGroupAccess: false),
            researcher(.GET, "\(base)/groups/\(groupId)", successStatus: .ok),
            // Studies
            researcher(.GET, "\(base)/studies/\(studyId)", successStatus: .ok),
            researcher(.GET, "\(base)/groups/\(groupId)/studies", successStatus: .ok),
            researcher(.PATCH, "\(base)/studies/\(studyId)", body: jsonData(patchBody()), successStatus: .ok),
            researcher(.POST, "\(base)/groups/\(groupId)/studies", body: jsonData(studyBody()), minRole: .admin, successStatus: .created),
            // Invitation Codes
            researcher(.GET, "\(base)/studies/\(studyId)/invitation-codes", successStatus: .ok),
            researcher(.POST, "\(base)/studies/\(studyId)/invitation-codes", body: jsonData(["count": 1] as [String: Any]), successStatus: .created),
            researcher(.DELETE, "\(base)/studies/\(studyId)/invitation-codes/\(dummyId)", successStatus: .notFound),
            // Published Studies & Enrollments
            researcher(.POST, "\(base)/studies/\(studyId)/publish", minRole: .admin, successStatus: .created),
            researcher(.GET, "\(base)/studies/\(studyId)/published", successStatus: .ok),
            AuthEndpoint(
                method: .GET,
                path: "\(base)/studies/\(studyId)/audit-events",
                body: nil,
                contentType: nil,
                role: .auditReader,
                successStatus: .ok
            ),
            researcher(.GET, "\(base)/studies/\(studyId)/enrollments", successStatus: .ok),

            // Publication above makes this study retained, including for administrators.
            researcher(.DELETE, "\(base)/studies/\(studyId)", minRole: .admin, successStatus: .conflict),

            // Components
            researcher(.GET, "\(base)/studies/\(studyId)/components", successStatus: .ok),
            researcher(.GET, "\(base)/studies/\(studyId)/components/informational/\(informationalId)", successStatus: .ok),
            researcher(.GET, "\(base)/studies/\(studyId)/components/questionnaire/\(questionnaireId)", successStatus: .ok),
            researcher(.GET, "\(base)/studies/\(studyId)/components/health-data/\(healthDataId)", successStatus: .ok),
            researcher(.POST, "\(base)/studies/\(studyId)/components/informational", body: informational, successStatus: .created),
            researcher(.POST, "\(base)/studies/\(studyId)/components/questionnaire", body: questionnaire, successStatus: .created),
            researcher(.POST, "\(base)/studies/\(studyId)/components/health-data", body: healthData, successStatus: .created),
            researcher(.PUT, "\(base)/studies/\(studyId)/components/informational/\(informationalId)", body: informational, successStatus: .ok),
            researcher(.PUT, "\(base)/studies/\(studyId)/components/questionnaire/\(questionnaireId)", body: questionnaire, successStatus: .ok),
            researcher(.PUT, "\(base)/studies/\(studyId)/components/health-data/\(healthDataId)", body: healthData, successStatus: .ok),
            // Component Schedules (use questionnaire — health-data doesn't support schedules)
            researcher(.GET, "\(base)/studies/\(studyId)/components/\(questionnaireId)/schedules", successStatus: .ok),
            researcher(.POST, "\(base)/studies/\(studyId)/components/\(questionnaireId)/schedules", body: scheduleBody, successStatus: .created),
            researcher(.GET, "\(base)/studies/\(studyId)/components/\(questionnaireId)/schedules/\(scheduleId)", successStatus: .ok),
            researcher(.PUT, "\(base)/studies/\(studyId)/components/\(questionnaireId)/schedules/\(scheduleId)", body: scheduleBody, successStatus: .ok),
            researcher(.DELETE, "\(base)/studies/\(studyId)/components/\(questionnaireId)/schedules/\(scheduleId)", successStatus: .noContent),
            // Components — destructive (after schedules, which depend on the component existing)
            researcher(.DELETE, "\(base)/studies/\(studyId)/components/\(healthDataId)", successStatus: .noContent),

            // Participant — profile & studies (fixture pre-created by participantAllowedActions)
            participant(.POST, "\(base)/participant/profile", successStatus: .conflict, body: jsonData(profileBody())),
            participant(.GET, "\(base)/participant/profile", successStatus: .ok),
            participant(.PUT, "\(base)/participant/profile", successStatus: .ok, body: jsonData(profileBody(firstName: "Updated"))),
            participant(.POST, "\(base)/participant/sources", successStatus: .ok, body: jsonData(["registrationID": dummyId.uuidString])),
            participant(.GET, "\(base)/participant/sources/\(dummyId)", successStatus: .notFound),
            participant(.POST, "\(base)/participant/sources/\(dummyId)/revoke", successStatus: .notFound),
            participant(
                .POST,
                "\(base)/participant/sources/\(dummyId)/event-receipts/lookup",
                successStatus: .notFound,
                body: jsonData(Components.Schemas.EventReceiptLookup(
                    producerEventIdentifier: .init(
                        system: "urn:uuid:11111111-1111-4111-8111-111111111111",
                        value: "e0:11111111-1111-4111-8111-111111111111:1"
                    ),
                    payloadSHA256: String(repeating: "0", count: 64),
                    targets: [.init(consentId: dummyId.uuidString, outputFullUrls: ["urn:uuid:point"])]
                ))
            ),
            participant(
                .POST,
                "\(base)/participant/sources/\(dummyId)/events",
                successStatus: .notFound,
                body: jsonData(Components.Schemas.EventSubmission(
                    eventBase64: Data("{}".utf8).base64EncodedString(),
                    targets: [.init(consentId: dummyId.uuidString, outputFullUrls: ["urn:uuid:point"]) ]
                ))
            ),
            participant(
                .POST,
                "\(base)/participant/sources/\(dummyId)/events/batch",
                successStatus: .notFound,
                body: jsonData(Components.Schemas.EventBatchSubmission(events: [.init(eventBase64: "e30=", targets: [])]))
            ),
            participant(
                .POST,
                "\(base)/participant/sources/\(dummyId)/events/\(dummyId)/attributions",
                successStatus: .notFound,
                body: jsonData(Components.Schemas.EventAttribution(
                    commandId: dummyId.uuidString,
                    targets: [.init(consentId: dummyId.uuidString, outputFullUrls: ["urn:uuid:point"])]
                ))
            ),
            participant(.GET, "\(base)/participant/studies", successStatus: .ok),
            participant(.GET, "\(base)/participant/studies/\(studyId)/\(dummyRevision)/bundle", successStatus: .notFound),
            participant(.POST, "\(base)/participant/studies/\(studyId)/enrollments", successStatus: .notFound, body: jsonData([String: String]())),
            participant(.GET, "\(base)/participant/enrollments", successStatus: .ok),
            participant(.GET, "\(base)/participant/enrollments/\(dummyId)/collection-plan", successStatus: .notFound),
            participant(.POST, "\(base)/participant/enrollments/\(dummyId)/withdraw", successStatus: .notFound),
            participant(.GET, "\(base)/participant/enrollments/\(dummyId)/consent-presentation?locale=en-US", successStatus: .notFound),
            participant(.GET, "\(base)/participant/enrollments/\(dummyId)/consents", successStatus: .notFound),
            participant(
                .POST,
                "\(base)/participant/enrollments/\(dummyId)/consents",
                successStatus: .notFound,
                body: ConsentRequestFixtures.authorizationBody(),
                contentType: .init(type: "multipart", subType: "form-data", parameters: ["boundary": "AuthTestBoundary"])
            ),
            participant(.GET, "\(base)/participant/enrollments/\(dummyId)/consents/\(dummyId)/pdf", successStatus: .notFound)
        ]
    }

    private static func normalizedRoutes(from app: Application) -> Set<String> {
        let healthRoute = "GET /\(apiBasePath)/health"
        return Set(
            app.routes.all.compactMap { route -> String? in
                let path = route.path
                    .map { component -> String in
                        switch component {
                        case .parameter:
                            return "*"
                        case .constant(let value):
                            return value
                        default:
                            return String(describing: component)
                        }
                    }
                    .joined(separator: "/")
                let normalized = "\(route.method.rawValue) /\(path)"
                return normalized == healthRoute ? nil : normalized
            }
        )
    }

    private static func normalizedTestedRoutes() -> Set<String> {
        Set(
            allEndpoints(.dummy)
                .map {
                    "\($0.method.rawValue) /\($0.path.split(separator: "?", maxSplits: 1).first ?? "")"
                        .replacingOccurrences(of: dummyUUID.uuidString, with: "*")
                        .replacingOccurrences(of: dummyRevision, with: "*")
                }
        )
    }
}

private func jsonData(_ dict: [String: Any]) -> Data? {
    try? JSONSerialization.data(withJSONObject: dict)
}

private func jsonData(_ value: some Encodable) -> Data? {
    try? JSONEncoder().encode(value)
}

private func profileBody(firstName: String = "Jane") -> [String: String] {
    ParticipantFixtures.profileBody(firstName: firstName)
}

private func studyBody(title: String = "X") -> [String: Any] {
    ["title": title, "icon": "heart"] as [String: Any]
}

private func patchBody() -> [String: Any] {
    ["details": ["en-US": ["title": "Updated"] as [String: Any]] as [String: Any]] as [String: Any]
}

private func scheduleBody() -> [String: Any] {
    [
        "scheduleDefinition": [
            "type": "repeated",
            "pattern": ["type": "daily", "hour": 9] as [String: Any]
        ] as [String: Any],
        "completionPolicy": "anytime",
        "notification": false
    ] as [String: Any]
}
