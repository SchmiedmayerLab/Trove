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


extension PublicationReadinessTests {
    static var unsupportedNativeRequirement: Components.Schemas.CollectionRequirement {
        .init(
            includeWorkoutRoutes: false,
            profile: CollectionObservationProfile.heartRate.rawValue,
            sourceTypeIdentifier: "HKQuantityTypeIdentifierUnimplementedSource",
            sourceKind: .participantApp
        )
    }

    static var unregisteredProviderRequirement: Components.Schemas.CollectionRequirement {
        .init(
            includeWorkoutRoutes: false,
            profile: CollectionObservationProfile.bodyWeight.rawValue,
            sourceTypeIdentifier: "getmeas:1",
            providerRegistrationId: UUID().uuidString.lowercased(),
            sourceKind: .serverWorker
        )
    }

    static func expectPublicationEvidence(
        _ publication: Components.Schemas.PublishedStudyResponse, component: UUID, sha256: String, app: Application
    ) async throws {
        let instrument = try #require(publication.instruments.first)
        #expect(publication.instruments.count == 1 && instrument.componentId == component.uuidString)
        #expect(instrument.sha256 == sha256 && instrument.language == "en-US" && instrument.translationLanguages == ["de"])
        #expect(instrument.administrationLanguages.map(\.language) == ["en-US", "de"])
        let approvals = try await QuestionnaireLanguageApproval.query(on: app.db).all()
        let approvalIDs = try Set(approvals.map { try $0.requireId().uuidString })
        #expect(Set(instrument.administrationLanguages.map(\.approvalId)) == approvalIDs)
        #expect(publication.definitionSchemaVersion == PublicationEvidence.currentDefinitionSchemaVersion)
        #expect(publication.contractVersion == FHIRValidationClient.contractVersion)
        #expect(publication.contractRevision == FHIRValidationClient.contractRevision)
        #expect(publication.validatorIdentity == QuestionnaireWorkerReply.identity)
        #expect(publication.executionCapability == QuestionnaireValidationService.executionCapability)
        let stored = try #require(try await PublishedStudy.find(UUID(uuidString: publication.id), on: app.db))
        #expect(stored.readinessFacts == StudyFixtures.completeReadinessFacts())
    }

    static func germanFixture() throws -> MultilingualQuestionnaireFixture {
        try #require(try MultilingualQuestionnaireFixture.all().first { $0.translationLanguage == "de" })
    }

    static func bilingualStudy(
        app: Application, token: String?, administration: QuestionnaireAdministration? = nil, removingItemTranslation: Bool = false
    ) async throws -> (study: UUID, component: UUID) {
        let group = try await GroupFixtures.createGroup(on: app.db)
        let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
        var resource = try #require(try JSONSerialization.jsonObject(with: try germanFixture().bytes()) as? [String: Any])
        if removingItemTranslation, var items = resource["item"] as? [[String: Any]] {
            items[0].removeValue(forKey: "_text")
            resource["item"] = items
        }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: resource, options: [.sortedKeys]), as: UTF8.self)
        let response = try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(study.requireId())/components/questionnaire", beforeRequest: { request in
            request.bearerAuth(token)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(study.draftRevision)\"")
            try request.encodeJSONBody(Components.Schemas.QuestionnaireComponentInput(
                name: "Café", data: .init(questionnaire: text), administrationLanguages: administration?.languages
            ))
        })
        try #require(response.status == .created)
        let created = try response.content.decode(Components.Schemas.QuestionnaireComponentResponse.self)
        return (try study.requireId(), try #require(UUID(uuidString: created.id)))
    }

    static func questionnaire(
        _ study: UUID, _ component: UUID, app: Application, token: String?
    ) async throws -> Components.Schemas.QuestionnaireComponentResponse {
        let response = try await app.sendRequest(.GET, "\(apiBasePath)/studies/\(study)/components/questionnaire/\(component)", beforeRequest: { request in
            request.bearerAuth(token)
        })
        try #require(response.status == .ok)
        return try response.content.decode(Components.Schemas.QuestionnaireComponentResponse.self)
    }

    static func replaceQuestionnaire(
        _ study: UUID, _ component: UUID, app: Application, token: String?, change: (inout [String: Any]) -> Void
    ) async throws -> Components.Schemas.QuestionnaireComponentResponse {
        let current = try await questionnaire(study, component, app: app, token: token)
        var resource = try #require(try JSONSerialization.jsonObject(with: Data(current.data.questionnaire.utf8)) as? [String: Any])
        change(&resource)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: resource, options: [.sortedKeys]), as: UTF8.self)
        let revision = try #require(try await Study.find(study, on: app.db)).draftRevision
        let response = try await app.sendRequest(.PUT, "\(apiBasePath)/studies/\(study)/components/questionnaire/\(component)", beforeRequest: { request in
            request.bearerAuth(token)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(revision)\"")
            try request.encodeJSONBody(Components.Schemas.QuestionnaireComponentInput(
                name: current.name, data: .init(questionnaire: text), administrationLanguages: current.administrationLanguages
            ))
        })
        try #require(response.status == .ok)
        return try response.content.decode(Components.Schemas.QuestionnaireComponentResponse.self)
    }

    static func validate(_ study: UUID, app: Application, token: String?) async throws -> Components.Schemas.StudyDraftValidation {
        let revision = try #require(try await Study.find(study, on: app.db)).draftRevision
        let response = try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(study)/draft/validations", beforeRequest: { request in
            request.bearerAuth(token)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(revision)\"")
        })
        try #require(response.status == .ok || response.status == .created)
        let report = try response.content.decode(Components.Schemas.StudyDraftValidation.self)
        #expect((response.status == .created) == (report.candidate != nil))
        return report
    }

    static func publish(
        _ study: UUID, revision: String, candidate: String, app: Application, token: String?
    ) async throws -> TestingHTTPResponse {
        try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(study)/publish", beforeRequest: { request in
            request.bearerAuth(token)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(revision)\"")
            try request.encodeJSONBody(Components.Schemas.StudyPublicationInput(validationId: candidate))
        })
    }

    static func publish(
        _ study: UUID, revision: UUID, candidate: String, app: Application, token: String?
    ) async throws -> TestingHTTPResponse {
        try await publish(study, revision: revision.uuidString, candidate: candidate, app: app, token: token)
    }

    static func patchResponse(
        _ study: UUID, revision: UUID, app: Application, token: String?, readiness: StudyReadinessFacts
    ) async throws -> TestingHTTPResponse {
        try await app.sendRequest(.PATCH, "\(apiBasePath)/studies/\(study)", beforeRequest: { request in
            request.bearerAuth(token)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(revision)\"")
            try request.encodeJSONBody(Components.Schemas.StudyPatchInput(readinessFacts: readiness))
        })
    }

    static func patch(
        _ study: UUID, app: Application, token: String?, readiness: StudyReadinessFacts
    ) async throws -> Components.Schemas.StudyResponse {
        let revision = try #require(try await Study.find(study, on: app.db)).draftRevision
        let response = try await patchResponse(study, revision: revision, app: app, token: token, readiness: readiness)
        try #require(response.status == .ok)
        return try response.content.decode(Components.Schemas.StudyResponse.self)
    }

    static func patchRequirements(
        _ study: UUID, revision: UUID, _ requirements: [Components.Schemas.CollectionRequirement], app: Application, token: String?
    ) async throws -> UUID {
        let response = try await app.sendRequest(.PATCH, "\(apiBasePath)/studies/\(study)", beforeRequest: { request in
            request.bearerAuth(token)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(revision)\"")
            try request.encodeJSONBody(Components.Schemas.StudyPatchInput(collectionRequirements: requirements))
        })
        try #require(response.status == .ok)
        return try #require(UUID(uuidString: try response.content.decode(Components.Schemas.StudyResponse.self).draftRevision))
    }

    static func auditActions(app: Application) async throws -> [String] {
        let database = try #require(app.db as? any SQLDatabase)
        let rows = try await database.raw("SELECT action FROM audit_events").all()
        return try rows.map { try $0.decode(column: "action", as: String.self) }
    }
}


extension Application {
    func approveLanguage(
        _ study: UUID, _ component: UUID, sha256: String, language: String, token: String?
    ) async throws -> TestingHTTPResponse {
        try await sendRequest(.POST, "\(apiBasePath)/studies/\(study)/components/\(component)/language-approvals", beforeRequest: { request in
            request.bearerAuth(token)
            try request.encodeJSONBody(Components.Schemas.QuestionnaireLanguageApprovalInput(sha256: sha256, language: language))
        })
    }
}
