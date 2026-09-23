//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Testing
import TroveAPIClient
@testable import TroveCLI


struct AuthoringClientTests {
    private let study = UUID()
    private let revision = UUID()
    private let delegation = UUID()

    private var studyResponse: Components.Schemas.StudyResponse {
        .init(
            draftRevision: revision.uuidString,
            collectionRequirements: [],
            id: study.uuidString,
            locales: [],
            icon: "heart",
            details: .init(),
            participationCriterion: .ageAtLeast(.init(_type: .ageAtLeast, age: 18)),
            consent: .init(),
            visibility: .unlisted,
            enrollmentConditions: .none
        )
    }

    private func client(_ transport: AuthoringTransport) throws -> AuthoringClient {
        let url = try #require(URL(string: "https://research.example/api/v0"))
        return AuthoringClient(serverURL: url, token: "synthetic-test-credential", transport: transport)
    }

    @Test
    func readsTypedDraftWithDelegation() async throws {
        let transport = try AuthoringTransport(response: studyResponse)
        let result = try await client(transport).getStudy(study, delegation: delegation)
        #expect(result == studyResponse)
        let records = await transport.records
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.request.method == .get)
        #expect(record.request.path == "/studies/\(study.uuidString)")
        #expect(record.request.headerFields[.authorization] == "Bearer synthetic-test-credential")
        #expect(record.request.headerFields[try #require(HTTPField.Name("Trove-Delegation-ID"))] == delegation.uuidString)
        #expect(record.request.headerFields[.ifMatch] == nil)
    }

    @Test
    func createsTypedStudyWithoutDelegation() async throws {
        let transport = try AuthoringTransport(response: studyResponse, status: 201)
        let group = UUID()
        let input = Components.Schemas.StudyCreateInput(title: "Synthetic study", icon: "heart")
        #expect(try await client(transport).createStudy(group: group, input: input) == studyResponse)
        let record = try #require(await transport.records.first)
        #expect(record.request.method == .post)
        #expect(record.request.path == "/groups/\(group.uuidString)/studies")
        #expect(try JSONDecoder().decode(Components.Schemas.StudyCreateInput.self, from: record.body) == input)
        #expect(record.request.headerFields[try #require(HTTPField.Name("Trove-Delegation-ID"))] == nil)
    }

    @Test
    func editSendsCapturedRevisionWithoutReadingFirst() async throws {
        let transport = try AuthoringTransport(response: studyResponse)
        let input = Components.Schemas.StudyPatchInput(icon: "leaf")
        _ = try await client(transport).editStudy(study, revision: revision, delegation: delegation, input: input)
        let records = await transport.records
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.request.method == .patch)
        #expect(record.request.path == "/studies/\(study.uuidString)")
        #expect(record.request.headerFields[.ifMatch] == CLIInput.revisionHeader(revision))
        #expect(record.request.headerFields[try #require(HTTPField.Name("Trove-Delegation-ID"))] == delegation.uuidString)
        #expect(try JSONDecoder().decode(Components.Schemas.StudyPatchInput.self, from: record.body) == input)
    }

    @Test
    func importsLocalizedQuestionnaire() async throws {
        let input = Components.Schemas.QuestionnaireComponentInput(
            name: "Wellbeing",
            data: .init([.enUS: QuestionnaireContent(questionnaire: "{\"resourceType\":\"Questionnaire\",\"status\":\"draft\"}")])
        )
        let response = Components.Schemas.QuestionnaireComponentResponse(id: UUID().uuidString, name: input.name, data: input.data)
        let transport = try AuthoringTransport(response: response, status: 201)
        #expect(try await client(transport).importQuestionnaire(study, revision: revision, delegation: delegation, input: input) == response)
        let record = try #require(await transport.records.first)
        #expect(record.request.path == "/studies/\(study.uuidString)/components/questionnaire")
        #expect(record.request.method == .post)
        #expect(record.request.headerFields[.ifMatch] == CLIInput.revisionHeader(revision))
        #expect(try JSONDecoder().decode(Components.Schemas.QuestionnaireComponentInput.self, from: record.body) == input)
    }

    @Test
    func validatesCapturedDraft() async throws {
        let receipt = Components.Schemas.StudyDraftValidation(
            id: UUID().uuidString,
            draftRevision: revision.uuidString,
            publicationRevision: 1,
            bundleSha256: String(repeating: "0", count: 64),
            validatorIdentity: "synthetic-validator",
            contractRevision: "synthetic-contract",
            executionCapability: "synthetic-capability",
            createdAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 3_600),
            questionnaires: []
        )
        let transport = try AuthoringTransport(response: receipt, status: 201)
        #expect(try await client(transport).validateStudy(study, revision: revision, delegation: delegation) == receipt)
        let record = try #require(await transport.records.first)
        #expect(record.request.path == "/studies/\(study.uuidString)/draft/validations")
        #expect(record.request.headerFields[.ifMatch] == CLIInput.revisionHeader(revision))
        #expect(record.request.headerFields[try #require(HTTPField.Name("Trove-Delegation-ID"))] == delegation.uuidString)
        #expect(record.body.isEmpty)
    }

    @Test
    func publicationUsesOnlySelectedCandidateAndRevision() async throws {
        let response = Components.Schemas.PublishedStudyResponse(
            id: UUID().uuidString, studyId: study.uuidString, revision: 1, visibility: .unlisted, publishedAt: Date(timeIntervalSince1970: 0)
        )
        let validation = UUID()
        let transport = try AuthoringTransport(response: response, status: 201)
        #expect(try await client(transport).publishStudy(study, revision: revision, validation: validation) == response)
        let records = await transport.records
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.request.path == "/studies/\(study.uuidString)/publish")
        #expect(record.request.headerFields[.ifMatch] == CLIInput.revisionHeader(revision))
        #expect(record.request.headerFields[try #require(HTTPField.Name("Trove-Delegation-ID"))] == nil)
        #expect(try JSONDecoder().decode(Components.Schemas.StudyPublicationInput.self, from: record.body).validationId == validation.uuidString)
    }

    @Test(arguments: [302, 401, 403, 409, 412, 422, 503])
    func failuresAreSafeAndNeverRetried(status: Int) async throws {
        let transport = try AuthoringTransport(response: ["detail": "Sensitive upstream content must not be printed"], status: status)
        await #expect(throws: CLIError.httpStatus(status)) {
            try await client(transport).editStudy(study, revision: revision, delegation: nil, input: .init(icon: "leaf"))
        }
        #expect(await transport.records.count == 1)
        #expect(!CLIError.httpStatus(status).description.contains("Sensitive"))
    }

    @Test
    func malformedSuccessDoesNotExposeItsBody() async throws {
        let transport = try AuthoringTransport(response: ["secret": "Sensitive body"])
        await #expect(throws: CLIError.requestFailed) {
            try await client(transport).getStudy(study, delegation: nil)
        }
        #expect(await transport.records.count == 1)
    }
}
