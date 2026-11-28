//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIClient
@testable import TroveCLI


struct StudyTasksClientTests {
    @Test
    func readsOnePageAndRefusesAnotherStudy() async throws {
        let study = UUID()
        let cursor = String(repeating: "a", count: 64)
        let page = Components.Schemas.StudyTaskPage(studyId: study.uuidString, items: [])
        let transport = try AuthoringTransport(response: page, headers: [.contentType: "application/json", .cacheControl: "no-store"])
        let client = try AuthoringClient(serverURL: #require(URL(string: "https://research.example/api/v0")), token: "", transport: transport)
        #expect(try await client.getStudyTasks(study, after: cursor, limit: 25) == page)
        let records = await transport.records
        try #require(records.count == 1)
        let url = try #require(records[0].request.path.flatMap { URLComponents(string: $0) })
        #expect(url.path == "/studies/\(study.uuidString)/tasks")
        #expect(url.queryItems?.contains(.init(name: "after", value: cursor)) == true)
        #expect(url.queryItems?.contains(.init(name: "limit", value: "25")) == true)
        await #expect(throws: CLIError.self) { try await client.getStudyTasks(UUID(), after: nil, limit: 25) }
    }
}
