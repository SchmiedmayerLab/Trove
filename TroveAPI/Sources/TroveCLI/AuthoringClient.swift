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
        let (response, responseBody) = try await next(authenticated, body, baseURL)
        guard (200..<300).contains(response.status.code) else {
            throw CLIError.httpStatus(response.status.code)
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

    func validateStudy(_ study: UUID, revision: UUID, delegation: UUID?) async throws -> Components.Schemas.StudyDraftValidation {
        try await request(revision: revision) { client in
            try await client.validateStudyDraft(.init(
                path: .init(studyId: study.uuidString),
                headers: .init(ifMatch: CLIInput.revisionHeader(revision), troveDelegationID: delegation?.uuidString)
            )).created.body.json
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
