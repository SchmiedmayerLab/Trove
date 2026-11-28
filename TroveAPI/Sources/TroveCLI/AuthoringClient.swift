//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import OpenAPIRuntime
import TroveAPIClient


private struct AuthoringAuthorization: ClientMiddleware {
    let token: String
    let expectedRevision: UUID?

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var authenticated = request
        if let expectedRevision {
            guard authenticated.headerFields[.ifMatch] != nil else {
                throw CLIError.requestFailed
            }
            // The runtime URI-escapes generated header strings. Supply the actual strong
            // entity tag from its typed source rather than decoding arbitrary header text.
            authenticated.headerFields[.ifMatch] = CLIInput.revisionHeader(expectedRevision)
        } else if authenticated.headerFields[.ifMatch] != nil {
            throw CLIError.requestFailed
        }
        authenticated.headerFields[.authorization] = "Bearer \(token)"
        let recording = operationID == Operations.GetStudyRecording.id
        if recording {
            authenticated.headerFields[.acceptEncoding] = "identity"
        }
        let (response, responseBody) = try await next(authenticated, body, baseURL)
        guard (200..<300).contains(response.status.code) else {
            throw CLIError.httpStatus(response.status.code)
        }
        if recording, let encoding = response.headerFields[.contentEncoding],
           encoding.trimmingCharacters(in: .whitespaces).lowercased() != "identity" {
            throw CLIError.requestFailed
        }
        return (response, responseBody)
    }
}


struct AuthoringClient: Sendable {
    private let serverURL: URL
    private let token: String
    private let transport: any ClientTransport

    init(serverURL: URL, token: String, transport: any ClientTransport) {
        self.serverURL = serverURL
        self.token = token
        self.transport = transport
    }

    func createStudy(group: UUID, input: Components.Schemas.StudyCreateInput) async throws -> Components.Schemas.StudyResponse {
        try await request(revision: nil) { client in
            try await client.postGroupsGroupIdStudies(.init(path: .init(groupId: group.uuidString), body: .json(input))).created.body.json
        }
    }

    func getStudy(_ study: UUID, delegation: UUID?) async throws -> Components.Schemas.StudyResponse {
        try await request(revision: nil) { client in
            try await client.getStudiesStudyId(.init(
                path: .init(studyId: study.uuidString),
                headers: .init(troveDelegationID: delegation?.uuidString)
            )).ok.body.json
        }
    }

    func editStudy(
        _ study: UUID,
        revision: UUID,
        delegation: UUID?,
        input: Components.Schemas.StudyPatchInput
    ) async throws -> Components.Schemas.StudyResponse {
        try await request(revision: revision) { client in
            try await client.patchStudiesStudyId(.init(
                path: .init(studyId: study.uuidString),
                headers: .init(troveDelegationID: delegation?.uuidString, ifMatch: CLIInput.revisionHeader(revision)),
                body: .json(input)
            )).ok.body.json
        }
    }

    func importQuestionnaire(
        _ study: UUID,
        revision: UUID,
        delegation: UUID?,
        input: Components.Schemas.QuestionnaireComponentInput
    ) async throws -> Components.Schemas.QuestionnaireComponentResponse {
        try await request(revision: revision) { client in
            try await client.postStudiesStudyIdComponentsQuestionnaire(.init(
                path: .init(studyId: study.uuidString),
                headers: .init(troveDelegationID: delegation?.uuidString, ifMatch: CLIInput.revisionHeader(revision)),
                body: .json(input)
            )).created.body.json
        }
    }

    func getQuestionnaire(
        _ study: UUID,
        component: UUID,
        delegation: UUID?
    ) async throws -> Components.Schemas.QuestionnaireComponentResponse {
        try await request(revision: nil) { client in
            let response = try await client.getStudiesStudyIdComponentsQuestionnaireComponentId(.init(
                path: .init(studyId: study.uuidString, componentId: component.uuidString),
                headers: .init(troveDelegationID: delegation?.uuidString)
            )).ok.body.json
            guard UUID(uuidString: response.id) == component else {
                throw CLIError.requestFailed
            }
            return response
        }
    }

    func validateStudy(_ study: UUID, revision: UUID, delegation: UUID?) async throws -> Components.Schemas.StudyDraftValidation {
        try await request(revision: revision) { client in
            let output = try await client.validateStudyDraft(.init(
                path: .init(studyId: study.uuidString),
                headers: .init(ifMatch: CLIInput.revisionHeader(revision), troveDelegationID: delegation?.uuidString)
            ))
            let report = switch output {
            case .created(let created): try created.body.json
            case .ok(let ok): try ok.body.json
            default: throw CLIError.requestFailed
            }
            // A candidate exists exactly for a valid result of the reviewed revision.
            guard UUID(uuidString: report.draftRevision) == revision,
                  (report.status == .valid) == (report.candidate != nil),
                  (report.status == .valid) == (output.createdIfPresent != nil) else {
                throw CLIError.requestFailed
            }
            return report
        }
    }

    func validateQuestionnaire(_ study: UUID, component: UUID, delegation: UUID?) async throws -> Components.Schemas.QuestionnaireValidation {
        try await request(revision: nil) { client in
            let result = try await client.validateStudyComponent(.init(
                path: .init(studyId: study.uuidString, componentId: component.uuidString),
                headers: .init(troveDelegationID: delegation?.uuidString)
            )).ok.body.json
            guard UUID(uuidString: result.componentId) == component else {
                throw CLIError.requestFailed
            }
            return result
        }
    }

    func publishStudy(_ study: UUID, revision: UUID, validation: UUID) async throws -> Components.Schemas.PublishedStudyResponse {
        try await request(revision: revision) { client in
            try await client.postStudiesStudyIdPublish(.init(
                path: .init(studyId: study.uuidString),
                headers: .init(ifMatch: CLIInput.revisionHeader(revision)),
                body: .json(.init(validationId: validation.uuidString))
            )).created.body.json
        }
    }

    func getStudyData(
        _ study: UUID,
        versions: Components.Schemas.StudyDataVersions,
        limit: Int,
        before: UUID?
    ) async throws -> Components.Schemas.StudyDataPage {
        guard (1...100).contains(limit) else {
            throw CLIError.invalidInput
        }
        return try await request(revision: nil) { client in
            let page = try await client.getStudyData(.init(
                path: .init(studyId: study.uuidString),
                query: .init(limit: limit, before: before?.uuidString, versions: versions)
            )).ok.body.json
            guard UUID(uuidString: page.studyId) == study, page.versions == versions,
                  page.records.count <= limit,
                  page.records.allSatisfy({ (1...512).contains($0.outputs.count) }),
                  page.records.reduce(0, { $0 + $1.outputs.count }) <= 1024 else {
                throw CLIError.requestFailed
            }
            return page
        }
    }

    func getStudyRecording(
        _ study: UUID,
        grant: UUID,
        versions: Components.Schemas.StudyDataVersions
    ) async throws -> HTTPBody {
        try await request(revision: nil) { client in
            try await client.getStudyRecording(.init(
                path: .init(studyId: study.uuidString, grantId: grant.uuidString),
                query: .init(versions: versions)
            )).ok.body.binary
        }
    }

    private func request<Value>(revision: UUID?, operation: (Client) async throws -> Value) async throws -> Value {
        do {
            let client = Client(
                serverURL: serverURL,
                configuration: .trove,
                transport: transport,
                middlewares: [AuthoringAuthorization(token: token, expectedRevision: revision)]
            )
            return try await operation(client)
        } catch {
            // Generated ClientError can retain request headers and response bodies; never print it.
            throw CLIError.sanitized(error)
        }
    }
}


extension Operations.ValidateStudyDraft.Output {
    fileprivate var createdIfPresent: Operations.ValidateStudyDraft.Output.Created? {
        if case .created(let created) = self { created } else { nil }
    }
}
