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


struct ValidationClientTests {
    private static let blocker = Components.Schemas.ValidationDiagnostic(
        severity: .error,
        source: .fhir,
        rule: "Synthetic_Error",
        path: "Questionnaire.item[0].text.extension[0]",
        language: "de",
        componentId: UUID().uuidString,
        message: "Synthetic finding",
        nextAction: "Synthetic next action"
    )

    private let study = UUID()
    private let revision = UUID()
    private let delegation = UUID()

    private var candidate: Components.Schemas.StudyPublicationCandidate {
        .init(
            id: UUID().uuidString,
            publicationRevision: 1,
            bundleSha256: String(repeating: "0", count: 64),
            validatorIdentity: "synthetic-validator",
            contractRevision: "synthetic-contract",
            executionCapability: "synthetic-capability",
            createdAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 3_600)
        )
    }

    private func client(_ transport: AuthoringTransport) throws -> AuthoringClient {
        let url = try #require(URL(string: "https://research.example/api/v0"))
        return AuthoringClient(serverURL: url, token: "synthetic-test-credential", transport: transport)
    }

    @Test
    func validatesCapturedDraft() async throws {
        let receipt = Components.Schemas.StudyDraftValidation(
            draftRevision: revision.uuidString, status: .valid, blockers: [], advisories: [], questionnaires: [], candidate: candidate, routes: []
        )
        let transport = try AuthoringTransport(response: receipt, status: 201)
        #expect(try await client(transport).validateStudy(study, revision: revision, delegation: delegation) == receipt)
        let record = try #require(await transport.records.first)
        #expect(record.request.path == "/studies/\(study.uuidString)/draft/validations")
        #expect(record.request.headerFields[.ifMatch] == CLIInput.revisionHeader(revision))
        #expect(record.request.headerFields[try #require(HTTPField.Name("Trove-Delegation-ID"))] == delegation.uuidString)
        #expect(record.body.isEmpty)
    }

    @Test(arguments: [Components.Schemas.ValidationStatus.invalid, .incomplete, .unavailable])
    func returnsBlockersWithoutCandidate(status: Components.Schemas.ValidationStatus) async throws {
        let report = Components.Schemas.StudyDraftValidation(
            draftRevision: revision.uuidString, status: status, blockers: [Self.blocker], advisories: [], questionnaires: [], routes: []
        )
        let transport = try AuthoringTransport(response: report, status: 200)
        #expect(try await client(transport).validateStudy(study, revision: revision, delegation: nil) == report)
        #expect(ValidationExit.code(for: status) == [.invalid: 2, .incomplete: 3, .unavailable: 4][status])
    }

    @Test(arguments: ["candidate-without-valid", "valid-without-candidate", "valid-not-created", "other-revision"])
    func inconsistentValidationReportIsRejected(change: String) async throws {
        let report = Components.Schemas.StudyDraftValidation(
            draftRevision: change == "other-revision" ? UUID().uuidString : revision.uuidString,
            status: change == "candidate-without-valid" ? .invalid : .valid,
            blockers: [],
            advisories: [],
            questionnaires: [],
            candidate: change == "valid-without-candidate" ? nil : candidate,
            routes: []
        )
        let created = !["valid-not-created", "candidate-without-valid"].contains(change)
        let transport = try AuthoringTransport(response: report, status: created ? 201 : 200)
        await #expect(throws: CLIError.requestFailed) {
            try await client(transport).validateStudy(study, revision: revision, delegation: nil)
        }
    }

    @Test
    func validatesStoredQuestionnaireComponent() async throws {
        let component = UUID()
        let result = Components.Schemas.QuestionnaireValidation(
            componentId: component.uuidString,
            draftRevision: revision.uuidString,
            status: .invalid,
            sha256: String(repeating: "0", count: 64),
            language: "en-US",
            translationLanguages: ["de"],
            validatorIdentity: "synthetic-validator",
            contractVersion: "0.8.2",
            contractRevision: "synthetic-contract",
            executionCapability: "synthetic-capability",
            diagnostics: [Self.blocker]
        )
        let transport = try AuthoringTransport(response: result)
        #expect(try await client(transport).validateQuestionnaire(study, component: component, delegation: delegation) == result)
        let record = try #require(await transport.records.first)
        #expect(record.request.method == .post)
        #expect(record.request.path == "/studies/\(study.uuidString)/components/\(component.uuidString)/validations")
        #expect(record.request.headerFields[.ifMatch] == nil)
        #expect(record.request.headerFields[try #require(HTTPField.Name("Trove-Delegation-ID"))] == delegation.uuidString)
        await #expect(throws: CLIError.requestFailed) {
            try await client(transport).validateQuestionnaire(study, component: UUID(), delegation: nil)
        }
    }
}
