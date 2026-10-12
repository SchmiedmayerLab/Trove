//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import XCTest


/// Mutates only the named synthetic study through the real researcher API on the local test stack.
@MainActor
enum StudyRevisionFixture {
    private struct Entry: Decodable {
        let id: String
        let title: String?
    }

    private struct Published: Decodable {
        let revision: Int
    }

    private struct Draft: Decodable {
        let draftRevision: UUID
    }

    private struct Validation: Decodable {
        let id: UUID
        let draftRevision: UUID
        let publicationRevision: Int
    }

    private struct PublicationInput: Encodable {
        let validationId: UUID
    }

    private struct Token: Decodable {
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }

        let accessToken: String
    }

    static func publishSecondRevision(studyTitle: String) async throws {
        var tokenRequest = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:8180/realms/trove/protocol/openid-connect/token")))
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Credentials belong to the disposable development realm, never a running study.
        tokenRequest.httpBody = Data("grant_type=password&client_id=trove-dev-cli&username=leland%40example.com&password=password123".utf8)
        let token = try JSONDecoder().decode(Token.self, from: await send(tokenRequest, expectedStatus: 200)).accessToken
        let groups = try JSONDecoder().decode([Entry].self, from: await request("groups", token: token))
        guard groups.count == 1, let group = groups.first else {
            XCTFail("Expected one synthetic researcher group.")
            throw URLError(.badServerResponse)
        }
        let studies = try JSONDecoder().decode([Entry].self, from: await request("groups/\(group.id)/studies", token: token))
            .filter { $0.title == studyTitle }
        guard studies.count == 1, let study = studies.first else {
            XCTFail("Expected one matching synthetic study.")
            throw URLError(.badServerResponse)
        }
        let consent = """
        Revision 2 adds a weekly check-in. Please review this updated synthetic study consent.

        <toggle id="agree" expected-value="true">I agree to participate.</toggle>

        <signature id="participant"/>
        """
        let body = try JSONSerialization.data(withJSONObject: [
            "consent": [
                "en-US": ["title": "Study Consent — Revision 2", "content": consent]
            ]
        ])
        let draft = try JSONDecoder().decode(Draft.self, from: await request("studies/\(study.id)", token: token))
        let updated = try JSONDecoder().decode(Draft.self, from: await request(
            "studies/\(study.id)", token: token, method: "PATCH", body: body, revision: draft.draftRevision
        ))
        try await publishValidatedRevision(studyID: study.id, token: token, revision: updated.draftRevision)
    }

    private static func publishValidatedRevision(studyID: String, token: String, revision: UUID) async throws {
        let validation = try JSONDecoder().decode(Validation.self, from: await request(
            "studies/\(studyID)/draft/validations", token: token, method: "POST", revision: revision, expectedStatus: 201
        ))
        guard validation.draftRevision == revision, validation.publicationRevision == 2 else {
            XCTFail("Expected the captured draft's second publication candidate.")
            throw URLError(.badServerResponse)
        }
        let publication = try JSONDecoder().decode(
            Published.self,
            from: await request(
                "studies/\(studyID)/publish",
                token: token,
                method: "POST",
                body: JSONEncoder().encode(PublicationInput(validationId: validation.id)),
                revision: validation.draftRevision,
                expectedStatus: 201
            )
        )
        XCTAssertEqual(publication.revision, 2, "The fixture must publish exactly the next revision.")
    }

    private static func request(
        _ path: String,
        token: String,
        method: String = "GET",
        body: Data? = nil,
        revision: UUID? = nil,
        expectedStatus: Int = 200
    ) async throws -> Data {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/api/v0/\(path)")))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let revision {
            request.setValue("\"\(revision.uuidString)\"", forHTTPHeaderField: "If-Match")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return try await send(request, expectedStatus: expectedStatus)
    }

    private static func send(_ request: URLRequest, expectedStatus: Int) async throws -> Data {
        var request = request
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
        guard status == expectedStatus else {
            // Do not attach response bodies or requests: the token response contains credentials.
            XCTFail("Local fixture request returned HTTP \(status); expected \(expectedStatus).")
            throw URLError(.badServerResponse)
        }
        return data
    }
}
