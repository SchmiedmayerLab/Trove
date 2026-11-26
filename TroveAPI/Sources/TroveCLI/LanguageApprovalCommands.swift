//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import ArgumentParser
import Foundation
import TroveAPIClient


struct RevokeLanguageApproval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "revoke-language-approval",
        abstract: "Revoke a questionnaire language approval using administrator authority.",
        discussion: "A candidate validated with the approval can no longer be published. Accepted publications keep their evidence."
    )
    @OptionGroup var connection: ConnectionOptions
    @Argument(transform: CLIInput.uuid) var study: UUID
    @Option(help: "The questionnaire component ID.", transform: CLIInput.uuid) var component: UUID
    @Option(help: "The approval ID.", transform: CLIInput.uuid) var approval: UUID

    mutating func run() async throws {
        let client = try connection.client()
        try CLIInput.write(try await client.revokeLanguageApproval(study, component: component, approval: approval))
    }
}


struct ApproveLanguage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "approve-language",
        abstract: "Approve one administration language of a questionnaire's exact stored resource using administrator authority.",
        discussion: """
            Name the SHA-256 of the resource you reviewed, as `trove study validate` or the component read reports it. \
            Any later edit of the resource requires a new approval. Approving does not change the draft revision; \
            validate the draft again before publishing.
            """
    )
    @OptionGroup var connection: ConnectionOptions
    @Argument(transform: CLIInput.uuid) var study: UUID
    @Option(help: "The questionnaire component ID.", transform: CLIInput.uuid) var component: UUID
    @Option(help: "SHA-256 of the stored resource you reviewed.") var sha256: String
    @Option(help: "The base language or a translation language of the resource, as written there.") var language: String

    mutating func run() async throws {
        guard sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (1...35).contains(language.count) else {
            throw CLIError.invalidInput
        }
        let client = try connection.client()
        try CLIInput.write(try await client.approveLanguage(study, component: component, sha256: sha256, language: language))
    }
}


extension AuthoringClient {
    func approveLanguage(
        _ study: UUID, component: UUID, sha256: String, language: String
    ) async throws -> Components.Schemas.QuestionnaireLanguageApproval {
        try await request(revision: nil) { client in
            let output = try await client.approveQuestionnaireLanguage(.init(
                path: .init(studyId: study.uuidString, componentId: component.uuidString),
                body: .json(.init(sha256: sha256, language: language))
            ))
            let approval = switch output {
            case .created(let created): try created.body.json
            case .ok(let existing): try existing.body.json
            default: throw CLIError.requestFailed
            }
            // The reply must describe the requested approval, in force.
            guard UUID(uuidString: approval.componentId) == component, approval.sha256 == sha256,
                  approval.language == language, approval.revokedAt == nil else {
                throw CLIError.requestFailed
            }
            return approval
        }
    }

    func revokeLanguageApproval(_ study: UUID, component: UUID, approval: UUID) async throws -> Components.Schemas.QuestionnaireLanguageApproval {
        try await request(revision: nil) { client in
            let revoked = try await client.revokeQuestionnaireLanguageApproval(.init(
                path: .init(studyId: study.uuidString, componentId: component.uuidString, approvalId: approval.uuidString)
            )).ok.body.json
            guard UUID(uuidString: revoked.id) == approval, UUID(uuidString: revoked.componentId) == component, revoked.revokedAt != nil else {
                throw CLIError.requestFailed
            }
            return revoked
        }
    }
}
