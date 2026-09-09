//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import SQLKit
import Testing
@testable import TroveServer
import VaporTesting


struct LegacyIngestionRetirementTests {
    @Test(arguments: [TestApp.Token.none, .participant(subject: "retired-ingress"), .researcher()])
    func legacyResourceUploadIsNotRegisteredAndCannotCreateData(identity: TestApp.Token) async throws {
        try await TestApp.withApp(token: identity) { app, token in
            let path = "\(apiBasePath)/participant/fhir/resource"
            #expect(!app.routes.all.contains { $0.path.map(\.description).joined(separator: "/") == path })
            let before = try await Participant.query(on: app.db).count()
            try await app.test(.POST, path, beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeJSONBody([
                    "resourceType": "Observation",
                    "status": "final",
                    "code": ["text": "Retired endpoint must not accept this record"]
                ] as [String: Any])
            }) { response in
                #expect(response.status == .notFound)
            }
            #expect(try await Participant.query(on: app.db).count() == before)
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(try await sql
                .raw("SELECT count(*) AS count FROM _fluent_migrations WHERE name = 'TroveServer.CreateFHIRResources'")
                .first())
            #expect(try row.decode(column: "count", as: Int.self) == 0)
        }
    }
}
