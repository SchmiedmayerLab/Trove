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


struct StudyDataClientTests {
    private let study = UUID()
    private let cursor = UUID()

    private func page(versions: Components.Schemas.StudyDataVersions = .current) -> Components.Schemas.StudyDataPage {
        .init(
            id: UUID().uuidString,
            studyId: study.uuidString,
            versions: versions,
            policy: .studyPointViewV1,
            records: [],
            nextBefore: cursor.uuidString
        )
    }

    private func client(_ transport: AuthoringTransport) throws -> AuthoringClient {
        let url = try #require(URL(string: "https://research.example/api/v0"))
        return AuthoringClient(serverURL: url, token: "synthetic-test-credential", transport: transport)
    }

    @Test(arguments: [Components.Schemas.StudyDataVersions.current, .history])
    func loadsOnlyRequestedPageWithInteractiveHeaders(versions: Components.Schemas.StudyDataVersions) async throws {
        let expected = page(versions: versions)
        let transport = try AuthoringTransport(response: expected, headers: [.contentType: "application/json", .cacheControl: "no-store"])
        #expect(try await client(transport).getStudyData(study, versions: versions, limit: 10, before: cursor) == expected)
        let records = await transport.records
        #expect(records.count == 1)
        let sent = try #require(records.first)
        let path = try #require(sent.request.path)
        let components = try #require(URLComponents(string: path))
        #expect(components.path == "/studies/\(study.uuidString)/data")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query == ["limit": "10", "before": cursor.uuidString, "versions": versions.rawValue])
        #expect(sent.request.method == .get)
        #expect(sent.request.headerFields[.authorization] == "Bearer synthetic-test-credential")
        #expect(sent.request.headerFields[.ifMatch] == nil)
        #expect(sent.request.headerFields[try #require(HTTPField.Name("Trove-Delegation-ID"))] == nil)
        #expect(sent.body.isEmpty)
    }

    @Test
    func keepsExactBundleBytesAndRejectsWrongStudyOrView() async throws {
        let original = Data(#"{"resourceType":"Bundle","value":12345678901234567890.123456789,"text":"é"}"#.utf8)
        var response = page()
        response.records = [
            .init(
                id: UUID().uuidString,
                bundleBase64: original.base64EncodedString(),
                outputs: (1...14).map { .init(fullUrl: "urn:uuid:synthetic-output-\($0)", isCurrent: true, sourceProfiles: []) }
            )
        ]
        let transport = try AuthoringTransport(response: response, headers: [.contentType: "application/json", .cacheControl: "no-store"])
        let received = try await client(transport).getStudyData(study, versions: .current, limit: 1, before: nil)
        #expect(Data(base64Encoded: try #require(received.records.first).bundleBase64) == original)
        await #expect(throws: CLIError.requestFailed) {
            try await client(transport).getStudyData(UUID(), versions: .current, limit: 1, before: nil)
        }
        await #expect(throws: CLIError.requestFailed) {
            try await client(transport).getStudyData(study, versions: .history, limit: 1, before: nil)
        }
    }

    @Test(arguments: [401, 403, 409, 503])
    func refusesWithoutRetryOrResponseDisclosure(status: Int) async throws {
        let transport = try AuthoringTransport(response: ["detail": "synthetic-sensitive-body"], status: status)
        await #expect(throws: CLIError.httpStatus(status)) {
            try await client(transport).getStudyData(study, versions: .current, limit: 20, before: nil)
        }
        #expect(await transport.records.count == 1)
        #expect(!CLIError.httpStatus(status).description.contains("synthetic-sensitive-body"))
    }

    @Test(arguments: [0, 101])
    func refusesInvalidLimitsBeforeNetworking(limit: Int) async throws {
        let transport = try AuthoringTransport(response: page())
        await #expect(throws: CLIError.invalidInput) {
            try await client(transport).getStudyData(study, versions: .current, limit: limit, before: nil)
        }
        #expect(await transport.records.isEmpty)
    }
}
