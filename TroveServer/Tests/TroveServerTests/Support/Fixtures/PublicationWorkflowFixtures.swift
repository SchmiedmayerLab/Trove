//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


/// Explicit authority and validator configuration for publication workflow tests.
enum PublicationWorkflowFixtures {
    static func withApp(
        storageProvider: any ObjectStorageProvider = InMemoryObjectStorageProvider(),
        validator: FHIRValidationClient? = nil,
        _ test: @escaping @Sendable (Application, String?) async throws -> Void
    ) async throws {
        let authority = GrantorAuthorityProvider { actor in
            .init(
                issuer: actor.issuer,
                subject: actor.subject,
                enabled: true,
                roles: [TestApp.researcherRole],
                groups: ["/Test Group/admin"]
            )
        }
        let effectiveValidator = validator ?? FHIRValidationClient(
            expectedIdentity: "sha256:" + String(repeating: "a", count: 64),
            sendForPurpose: { _, _ in
                Issue.record("These publication storage fixtures contain no questionnaires; unexpected resources must not skip validation")
                return (503, Data())
            }
        )
        try await TestApp.withApp(storageProvider: storageProvider, validator: effectiveValidator, grantorAuthority: authority, test)
    }

    static func validate(_ studyID: UUID, app: Application, token: String?) async throws -> TestingHTTPResponse {
        let study = try #require(try await Study.find(studyID, on: app.db))
        return try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(studyID)/draft/validations", beforeRequest: { request in
            request.bearerAuth(token)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(study.draftRevision)\"")
        })
    }

    static func publish(_ studyID: UUID, app: Application, token: String?) async throws -> TestingHTTPResponse {
        let validation = try await validate(studyID, app: app, token: token)
        try #require(validation.status == .created)
        let candidate = try validation.content.decode(Components.Schemas.StudyDraftValidation.self)
        return try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(studyID)/publish", beforeRequest: { request in
            request.bearerAuth(token)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(candidate.draftRevision)\"")
            try request.encodeJSONBody(Components.Schemas.StudyPublicationInput(validationId: candidate.id))
        })
    }
}
