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


let dummyUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
let dummyRevision = "99999"

struct FixtureIDs: Sendable {
    static let dummy = FixtureIDs(
        groupId: dummyUUID,
        studyId: dummyUUID,
        healthDataId: dummyUUID,
        informationalId: dummyUUID,
        questionnaireId: dummyUUID,
        scheduleId: dummyUUID,
        draftRevision: dummyUUID,
        validationID: dummyUUID
    )

    let groupId: UUID
    let studyId: UUID
    let healthDataId: UUID
    let informationalId: UUID
    let questionnaireId: UUID
    let scheduleId: UUID
    let draftRevision: UUID
    let validationID: UUID
}

// MARK: - Static Helpers

extension AuthIntegrationTests {
    private struct ValidatorReply: Encodable {
        let valid = true
        let sha256: String
        let contractRevision = FHIRValidationClient.contractRevision
        let validatorIdentity = AuthIntegrationTests.validatorIdentity
        let purpose = "questionnaire"
    }

    static let validatorIdentity = "sha256:" + String(repeating: "a", count: 64)

    static var validator: FHIRValidationClient {
        .init(expectedIdentity: validatorIdentity, sendForPurpose: { purpose, bytes in
            #expect(purpose == .questionnaire)
            return (200, try JSONEncoder().encode(ValidatorReply(sha256: ArtifactStore.digest(bytes))))
        })
    }

    static var authority: GrantorAuthorityProvider {
        .init { actor in
            .init(
                issuer: actor.issuer,
                subject: actor.subject,
                enabled: true,
                roles: [TestApp.researcherRole],
                groups: ["/Test Group/admin"]
            )
        }
    }

    static func researcher(
        _ method: HTTPMethod,
        _ path: String,
        body: Data? = nil,
        draftRevision: UUID? = nil,
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
            successStatus: successStatus,
            ifMatch: draftRevision.map { "\"\($0)\"" }
        )
    }

    static func participant(
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
    static func allEndpoints(_ ids: FixtureIDs) -> [AuthEndpoint] {
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
            researcher(.PATCH, "\(base)/studies/\(studyId)", body: jsonData(patchBody()), draftRevision: ids.draftRevision, successStatus: .ok),
            researcher(.POST, "\(base)/groups/\(groupId)/studies", body: jsonData(studyBody()), minRole: .admin, successStatus: .created),
            // Invitation Codes
            researcher(.GET, "\(base)/studies/\(studyId)/invitation-codes", successStatus: .ok),
            researcher(.POST, "\(base)/studies/\(studyId)/invitation-codes", body: jsonData(["count": 1] as [String: Any]), successStatus: .created),
            researcher(.DELETE, "\(base)/studies/\(studyId)/invitation-codes/\(dummyId)", successStatus: .notFound),
            // Published Studies & Enrollments
            researcher(
                .POST,
                "\(base)/studies/\(studyId)/publish",
                body: jsonData(Components.Schemas.StudyPublicationInput(validationId: ids.validationID.uuidString)),
                draftRevision: ids.draftRevision,
                minRole: .admin,
                successStatus: .created
            ),
            researcher(.POST, "\(base)/studies/\(studyId)/draft/validations", draftRevision: ids.draftRevision, successStatus: .created),
            researcher(.GET, "\(base)/studies/\(studyId)/delegations", successStatus: .ok),
            researcher(
                .POST,
                "\(base)/studies/\(studyId)/delegations",
                body: jsonData(Components.Schemas.StudyDelegationInput(
                    clientId: "trove-draft-editor", preset: .editStudyDraft, expiresAt: Date().addingTimeInterval(3600)
                )),
                successStatus: .created
            ),
            researcher(.POST, "\(base)/studies/\(studyId)/delegations/\(dummyId)/revoke", successStatus: .forbidden),
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

            // The positive administrator fixture has an accepted publication.
            researcher(.DELETE, "\(base)/studies/\(studyId)", draftRevision: ids.draftRevision, minRole: .admin, successStatus: .conflict),

            // Components
            researcher(.GET, "\(base)/studies/\(studyId)/components", successStatus: .ok),
            researcher(.GET, "\(base)/studies/\(studyId)/components/informational/\(informationalId)", successStatus: .ok),
            researcher(.GET, "\(base)/studies/\(studyId)/components/questionnaire/\(questionnaireId)", successStatus: .ok),
            researcher(.GET, "\(base)/studies/\(studyId)/components/health-data/\(healthDataId)", successStatus: .ok),
            researcher(.POST, "\(base)/studies/\(studyId)/components/informational", body: informational, draftRevision: ids.draftRevision, successStatus: .created),
            researcher(.POST, "\(base)/studies/\(studyId)/components/questionnaire", body: questionnaire, draftRevision: ids.draftRevision, successStatus: .created),
            researcher(.POST, "\(base)/studies/\(studyId)/components/health-data", body: healthData, draftRevision: ids.draftRevision, successStatus: .created),
            researcher(.PUT, "\(base)/studies/\(studyId)/components/informational/\(informationalId)", body: informational, draftRevision: ids.draftRevision, successStatus: .ok),
            researcher(.PUT, "\(base)/studies/\(studyId)/components/questionnaire/\(questionnaireId)", body: questionnaire, draftRevision: ids.draftRevision, successStatus: .ok),
            researcher(.PUT, "\(base)/studies/\(studyId)/components/health-data/\(healthDataId)", body: healthData, draftRevision: ids.draftRevision, successStatus: .ok),
            // Component Schedules (use questionnaire — health-data doesn't support schedules)
            researcher(.GET, "\(base)/studies/\(studyId)/components/\(questionnaireId)/schedules", successStatus: .ok),
            researcher(.POST, "\(base)/studies/\(studyId)/components/\(questionnaireId)/schedules", body: scheduleBody, draftRevision: ids.draftRevision, successStatus: .created),
            researcher(.GET, "\(base)/studies/\(studyId)/components/\(questionnaireId)/schedules/\(scheduleId)", successStatus: .ok),
            researcher(.PUT, "\(base)/studies/\(studyId)/components/\(questionnaireId)/schedules/\(scheduleId)", body: scheduleBody, draftRevision: ids.draftRevision, successStatus: .ok),
            researcher(.DELETE, "\(base)/studies/\(studyId)/components/\(questionnaireId)/schedules/\(scheduleId)", draftRevision: ids.draftRevision, successStatus: .noContent),
            // Components — destructive (after schedules, which depend on the component existing)
            researcher(.DELETE, "\(base)/studies/\(studyId)/components/\(healthDataId)", draftRevision: ids.draftRevision, successStatus: .noContent),

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

    static func normalizedRoutes(from app: Application) -> Set<String> {
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

    static func normalizedTestedRoutes() -> Set<String> {
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
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try? encoder.encode(value)
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
