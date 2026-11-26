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
        get throws {
            try .init(
                enrollmentPeriod: .init(calendar: .gregorian, timeZone: "UTC"),
                readinessFacts: .init(content: .init(), contacts: []),
                draftRevision: revision.uuidString,
                collectionRequirements: [],
                receivesDeviceUnitIdentifiers: false,
                id: study.uuidString,
                locales: [],
                icon: "heart",
                details: .init(sourceLanguage: Self.english(), source: .init(title: "Synthetic study")),
                participationCriterion: .ageAtLeast(.init(_type: .ageAtLeast, age: 18)),
                consent: .init(),
                visibility: .unlisted,
                enrollmentConditions: .none
            )
        }
    }

    private static func english() throws -> LanguageTag {
        try #require(LanguageTag(rawValue: "en"))
    }

    private func client(_ transport: AuthoringTransport) throws -> AuthoringClient {
        let url = try #require(URL(string: "https://research.example/api/v0"))
        return AuthoringClient(serverURL: url, token: "synthetic-test-credential", transport: transport)
    }

    @Test
    func readsTypedDraftWithDelegation() async throws {
        let transport = try AuthoringTransport(response: studyResponse)
        let result = try await client(transport).getStudy(study, delegation: delegation)
        #expect(try result == studyResponse)
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
        let input = try Components.Schemas.StudyCreateInput(title: "Synthetic study", sourceLanguage: Self.english(), icon: "heart")
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
    func importsAndExportsOneMultilingualQuestionnaire() async throws {
        for fixture in try MultilingualQuestionnaireFixture.all() {
            let input = try CLIInput.questionnaire(file: fixture.url.path, name: "Wellbeing")
            let response = Components.Schemas.QuestionnaireComponentResponse(
                id: UUID().uuidString,
                name: input.name,
                data: input.data,
                language: fixture.language,
                translationLanguages: fixture.translationLanguages,
                sha256: String(repeating: "0", count: 64),
                administrationLanguages: [fixture.language],
                languageApprovals: []
            )
            let component = try #require(UUID(uuidString: response.id))
            let transport = try AuthoringTransport(response: response, status: 201)
            #expect(try await client(transport).importQuestionnaire(study, revision: revision, delegation: delegation, input: input) == response)
            let record = try #require(await transport.records.first)
            #expect(record.request.path == "/studies/\(study.uuidString)/components/questionnaire")
            #expect(record.request.method == .post)
            #expect(record.request.headerFields[.ifMatch] == CLIInput.revisionHeader(revision))
            let sent = try JSONDecoder().decode(Components.Schemas.QuestionnaireComponentInput.self, from: record.body)
            #expect(Data(sent.data.questionnaire.utf8) == (try fixture.bytes()))

            let exportTransport = try AuthoringTransport(response: response)
            let exported = try await client(exportTransport).getQuestionnaire(study, component: component, delegation: delegation)
            #expect(Data(exported.data.questionnaire.utf8) == (try fixture.bytes()))
            let read = try #require(await exportTransport.records.first)
            #expect(read.request.method == .get)
            #expect(read.request.path == "/studies/\(study.uuidString)/components/questionnaire/\(component.uuidString)")
            #expect(read.request.headerFields[try #require(HTTPField.Name("Trove-Delegation-ID"))] == delegation.uuidString)
            #expect(read.request.headerFields[.ifMatch] == nil)
        }
    }

    @Test
    func exportWritesTheStoredResourceExactly() async throws {
        for fixture in try MultilingualQuestionnaireFixture.all() {
            let bytes = try fixture.bytes()
            let component = UUID()
            let response = Components.Schemas.QuestionnaireComponentResponse(
                id: component.uuidString,
                name: "Wellbeing",
                data: QuestionnaireContent(questionnaire: String(decoding: bytes, as: UTF8.self)),
                language: fixture.language,
                translationLanguages: fixture.translationLanguages,
                sha256: String(repeating: "0", count: 64),
                administrationLanguages: [fixture.language],
                languageApprovals: []
            )
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("trove-cli-export-\(UUID()).json")
            try Data().write(to: output)
            defer { try? FileManager.default.removeItem(at: output) }
            let handle = try FileHandle(forWritingTo: output)
            try await ExportQuestionnaire.export(
                client: client(AuthoringTransport(response: response)),
                study: study,
                component: component,
                delegation: nil,
                to: handle
            )
            try handle.close()
            #expect(try Data(contentsOf: output) == bytes)
        }
    }

    @Test
    func exportRejectsADifferentComponent() async throws {
        let response = Components.Schemas.QuestionnaireComponentResponse(
            id: UUID().uuidString,
            name: "Other",
            data: QuestionnaireContent(questionnaire: "{}"),
            translationLanguages: [],
            sha256: String(repeating: "0", count: 64),
            administrationLanguages: [],
            languageApprovals: []
        )
        let transport = try AuthoringTransport(response: response)
        await #expect(throws: CLIError.requestFailed) {
            try await client(transport).getQuestionnaire(study, component: UUID(), delegation: nil)
        }
    }

    @Test
    func publicationUsesOnlySelectedCandidateAndRevision() async throws {
        let response = Components.Schemas.PublishedStudyResponse(
            id: UUID().uuidString,
            studyId: study.uuidString,
            revision: 1,
            visibility: .unlisted,
            publishedAt: Date(timeIntervalSince1970: 0),
            definitionSchemaVersion: "0.14.0",
            contractVersion: "0.8.2",
            contractRevision: "synthetic-contract",
            validatorIdentity: "synthetic-validator",
            executionCapability: "synthetic-capability",
            instruments: [],
            unavailableCollectionRequirements: []
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
