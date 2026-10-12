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
import TroveAPIServer
@testable import TroveServer
import VaporTesting


struct StudyPublicationCandidateTests {
    private struct Reply: Encodable {
        let valid = true
        let sha256: String
        let contractRevision = FHIRValidationClient.contractRevision
        let validatorIdentity = StudyPublicationCandidateTests.identity
        let purpose = "questionnaire"
    }

    private static let identity = "sha256:" + String(repeating: "a", count: 64)
    private static var authority: GrantorAuthorityProvider {
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

    private static func validator(unavailable: Bool = false) -> FHIRValidationClient {
        .init(expectedIdentity: identity, sendForPurpose: { purpose, bytes in
            #expect(purpose == .questionnaire)
            if unavailable {
                return (503, Data())
            }
            return (200, try JSONEncoder().encode(Reply(sha256: ArtifactStore.digest(bytes))))
        })
    }

    @Test
    func exactHTTPRetryPreservesReviewedIdentityAfterDraftChanges() async throws {
        try await TestApp.withApp(validator: Self.validator(), grantorAuthority: Self.authority) { app, token in
            let study = try await Self.study(on: app)
            let candidate = try await Self.validate(study, app: app, token: token)
            let first = try await Self.publish(study, candidate: candidate, app: app, token: token)
            #expect(first.status == .created)
            let accepted = try first.content.decode(Components.Schemas.PublishedStudyResponse.self)
            #expect(accepted.id == candidate.id)

            let edit = try await app.sendRequest(.PATCH, "\(apiBasePath)/studies/\(study.requireId())", beforeRequest: { request in
                request.bearerAuth(token)
                request.headers.replaceOrAdd(name: "If-Match", value: Self.tag(study.draftRevision))
                try request.encodeJSONBody(Components.Schemas.StudyPatchInput(icon: "later-draft"))
            })
            #expect(edit.status == .ok)
            let retried = try await Self.publish(study, candidate: candidate, app: app, token: token)
            #expect(retried.status == .created)
            let repeated = try retried.content.decode(Components.Schemas.PublishedStudyResponse.self)
            #expect(repeated == accepted)
            #expect(try await PublishedStudy.query(on: app.db).count() == 1)
            let stored = try #require(try await PublishedStudy.find(UUID(uuidString: candidate.id), on: app.db))
            #expect(stored.bundleDigest == candidate.bundleSha256)
            #expect(stored.artifactID == (try await StudyPublicationCandidate.find(stored.requireId(), on: app.db))?.artifactID)

            let wrongRevision = try await Self.publish(study, candidate: candidate, app: app, token: token, revision: UUID())
            #expect(wrongRevision.status == .preconditionFailed)
            #expect(try await PublishedStudy.query(on: app.db).count() == 1)
        }
    }

    @Test
    func draftChangeAfterValidationCannotPublishOrRetainTheArchive() async throws {
        try await TestApp.withApp(validator: Self.validator(), grantorAuthority: Self.authority) { app, token in
            let study = try await Self.study(on: app)
            let candidate = try await Self.validate(study, app: app, token: token)
            let edit = try await app.sendRequest(.PATCH, "\(apiBasePath)/studies/\(study.requireId())", beforeRequest: { request in
                request.bearerAuth(token)
                request.headers.replaceOrAdd(name: "If-Match", value: Self.tag(study.draftRevision))
                try request.encodeJSONBody(Components.Schemas.StudyPatchInput(icon: "changed-before-acceptance"))
            })
            #expect(edit.status == .ok)
            #expect(try await Self.publish(study, candidate: candidate, app: app, token: token).status == .preconditionFailed)
            #expect(try await PublishedStudy.query(on: app.db).count() == 0)
            #expect(try await StoredArtifact.query(on: app.db).filter(\.$state == .retained).count() == 0)
        }
    }

    @Test
    func mandatoryAuditFailureRollsBackPublicationAndArtifactRetention() async throws {
        try await TestApp.withApp(validator: Self.validator(), grantorAuthority: Self.authority) { app, token in
            let study = try await Self.study(on: app)
            let candidate = try await Self.validate(study, app: app, token: token)
            try await app.db.schema("audit_events").delete()
            #expect(try await Self.publish(study, candidate: candidate, app: app, token: token).status == .internalServerError)
            #expect(try await PublishedStudy.query(on: app.db).count() == 0)
            #expect(try await StoredArtifact.query(on: app.db).filter(\.$state == .ready).count() == 1)
        }
    }

    @Test
    func unavailableValidatorCannotCreateCandidateOrArtifact() async throws {
        try await TestApp.withApp(validator: Self.validator(unavailable: true), grantorAuthority: Self.authority) { app, token in
            let study = try await Self.study(on: app)
            let response = try await Self.validationResponse(study, app: app, token: token)
            #expect(response.status == .serviceUnavailable)
            #expect(try await StudyPublicationCandidate.query(on: app.db).count() == 0)
            #expect(try await StoredArtifact.query(on: app.db).count() == 0)
            #expect(try await PublishedStudy.query(on: app.db).count() == 0)
        }
    }

    @Test
    func reviewedCandidateCannotBeRewritten() async throws {
        try await TestApp.withApp(validator: Self.validator(), grantorAuthority: Self.authority) { app, token in
            let study = try await Self.study(on: app)
            let response = try await Self.validate(study, app: app, token: token)
            let candidate = try #require(try await StudyPublicationCandidate.find(UUID(uuidString: response.id), on: app.db))
            candidate.expiresAt = Date().addingTimeInterval(7200)
            await #expect(throws: (any Error).self) { try await candidate.update(on: app.db) }
            let restored = try #require(try await StudyPublicationCandidate.find(candidate.requireId(), on: app.db))
            #expect(abs(restored.expiresAt.timeIntervalSince(response.expiresAt)) < 0.001)
        }
    }
}


extension StudyPublicationCandidateTests {
    private static func tag(_ revision: UUID) -> String { "\"\(revision.uuidString)\"" }

    private static func study(on app: Application) async throws -> Study {
        let group = try await GroupFixtures.createGroup(on: app.db)
        let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
        let componentID = UUID()
        let questionnaire = """
        {
          "resourceType":"Questionnaire","id":"\(componentID)","language":"en-US",
          "meta":{"profile":["https://grovealliance.org/fhir/questionnaire/StructureDefinition/grove-questionnaire"]},
          "extension":[{"url":"http://hl7.org/fhir/StructureDefinition/artifact-versionAlgorithm",
            "valueCoding":{"system":"http://hl7.org/fhir/version-algorithm","code":"semver"}}],
          "url":"https://example.org/fhir/Questionnaire/synthetic","version":"1.0.0",
          "title":"Synthetic Branching","status":"active","subjectType":["Patient"],
          "item":[{"linkId":"completed","text":"Completed?","type":"boolean","required":true},
            {"linkId":"duration","text":"Minutes?","type":"integer","required":true,
             "enableWhen":[{"question":"completed","operator":"=","answerBoolean":true}]}]
        }
        """
        let component = Component(
            studyId: try study.requireId(),
            data: .questionnaire(.init([.enUS: .init(questionnaire: questionnaire)])),
            name: "Synthetic Questionnaire",
            id: componentID
        )
        try await component.create(on: app.db)
        return study
    }

    private static func validationResponse(_ study: Study, app: Application, token: String?) async throws -> TestingHTTPResponse {
        try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(study.requireId())/draft/validations", beforeRequest: { request in
            request.bearerAuth(token)
            request.headers.replaceOrAdd(name: "If-Match", value: tag(study.draftRevision))
        })
    }

    private static func validate(_ study: Study, app: Application, token: String?) async throws -> Components.Schemas.StudyDraftValidation {
        let response = try await validationResponse(study, app: app, token: token)
        try #require(response.status == .created)
        let candidate = try response.content.decode(Components.Schemas.StudyDraftValidation.self)
        #expect(candidate.questionnaires.count == 1)
        return candidate
    }

    private static func publish(
        _ study: Study, candidate: Components.Schemas.StudyDraftValidation, app: Application, token: String?, revision: UUID? = nil
    ) async throws -> TestingHTTPResponse {
        try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(study.requireId())/publish", beforeRequest: { request in
            request.bearerAuth(token)
            request.headers.replaceOrAdd(name: "If-Match", value: tag(revision ?? study.draftRevision))
            try request.encodeJSONBody(Components.Schemas.StudyPublicationInput(validationId: candidate.id))
        })
    }
}
