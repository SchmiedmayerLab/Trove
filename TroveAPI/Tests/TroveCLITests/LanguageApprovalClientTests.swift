//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import ArgumentParser
import Foundation
import HTTPTypes
import Testing
import TroveAPIClient
@testable import TroveCLI


struct LanguageApprovalClientTests {
    private let study = UUID()
    private let component = UUID()
    private let digest = String(repeating: "a", count: 64)

    private func client(_ transport: AuthoringTransport) throws -> AuthoringClient {
        let url = try #require(URL(string: "https://research.example/api/v0"))
        return AuthoringClient(serverURL: url, token: "synthetic-test-credential", transport: transport)
    }

    private func approval(
        language: String = "de",
        revoked: Bool = false,
        component: UUID? = nil
    ) -> Components.Schemas.QuestionnaireLanguageApproval {
        .init(
            id: UUID().uuidString,
            componentId: (component ?? self.component).uuidString,
            sha256: digest,
            language: language,
            approvedAt: Date(timeIntervalSince1970: 0),
            revokedAt: revoked ? Date(timeIntervalSince1970: 60) : nil
        )
    }

    @Test(arguments: [201, 200])
    func approvesTheReviewedDigestAndLanguage(status: Int) async throws {
        let expected = approval()
        let transport = try AuthoringTransport(response: expected, status: status)
        let result = try await client(transport).approveLanguage(study, component: component, sha256: digest, language: "de")
        #expect(result == expected)
        let record = try #require(await transport.records.first)
        #expect(record.request.method == .post)
        #expect(record.request.path == "/studies/\(study.uuidString)/components/\(component.uuidString)/language-approvals")
        #expect(record.request.headerFields[.ifMatch] == nil)
        #expect(record.request.headerFields[try #require(HTTPField.Name("Trove-Delegation-ID"))] == nil)
        let body = try JSONDecoder().decode(Components.Schemas.QuestionnaireLanguageApprovalInput.self, from: record.body)
        #expect(body == .init(sha256: digest, language: "de"))
    }

    @Test(arguments: ["language", "component", "revoked"])
    func rejectsAReplyForAnotherApproval(change: String) async throws {
        let reply = approval(
            language: change == "language" ? "fr" : "de",
            revoked: change == "revoked",
            component: change == "component" ? UUID() : nil
        )
        let transport = try AuthoringTransport(response: reply, status: 201)
        await #expect(throws: CLIError.requestFailed) {
            try await client(transport).approveLanguage(study, component: component, sha256: digest, language: "de")
        }
    }

    @Test
    func revokesTheNamedApproval() async throws {
        let revoked = approval(revoked: true)
        let id = try #require(UUID(uuidString: revoked.id))
        let transport = try AuthoringTransport(response: revoked)
        #expect(try await client(transport).revokeLanguageApproval(study, component: component, approval: id) == revoked)
        let record = try #require(await transport.records.first)
        #expect(record.request.path == "/studies/\(study.uuidString)/components/\(component.uuidString)/language-approvals/\(revoked.id)/revoke")
        await #expect(throws: CLIError.requestFailed) {
            try await client(try AuthoringTransport(response: approval())).revokeLanguageApproval(study, component: component, approval: id)
        }
    }

    @Test(arguments: ["ABCDEF", String(repeating: "A", count: 64), String(repeating: "g", count: 64)])
    func approvalCommandRejectsMalformedDigestsBeforeConnecting(digest: String) async throws {
        var command = try ApproveLanguage.parse([
            study.uuidString, "--component", component.uuidString, "--sha256", digest, "--language", "de", "--server", "https://research.example/api/v0"
        ])
        await #expect(throws: CLIError.invalidInput) { try await command.run() }
    }

    @Test(arguments: ["de DE", " de", "de\t", String(repeating: "x", count: 36), ""])
    func approvalCommandRejectsMalformedLanguagesBeforeConnecting(language: String) async throws {
        var command = try ApproveLanguage.parse([
            study.uuidString,
            "--component",
            component.uuidString,
            "--sha256",
            digest,
            "--language",
            language,
            "--server",
            "https://research.example/api/v0"
        ])
        await #expect(throws: CLIError.invalidInput) { try await command.run() }
    }
}
