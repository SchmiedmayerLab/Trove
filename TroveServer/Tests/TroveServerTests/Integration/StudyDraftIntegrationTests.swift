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


struct StudyDraftIntegrationTests {
    @Test
    func staleHTTPWritePreservesAcceptedDraft() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let initial = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let studyID = try initial.requireId()
            let tag = "\"\(initial.draftRevision.uuidString)\""

            for (icon, expectedStatus) in [("accepted", 200), ("stale", 412)] {
                try await app.test(.PATCH, "\(apiBasePath)/studies/\(studyID)", beforeRequest: { request in
                    request.bearerAuth(token)
                    request.headers.replaceOrAdd(name: "If-Match", value: tag)
                    try request.encodeJSONBody(Components.Schemas.StudyPatchInput(icon: icon))
                }) { response in
                    #expect(response.status.code == expectedStatus)
                }
            }

            let stored = try #require(try await Study.find(studyID, on: app.db))
            #expect(stored.icon == "accepted")
            #expect(stored.draftRevision != initial.draftRevision)
        }
    }

    @Test
    func missingPreconditionCannotMutateDraft() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let initial = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let studyID = try initial.requireId()
            try await app.test(.PATCH, "\(apiBasePath)/studies/\(studyID)", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeJSONBody(Components.Schemas.StudyPatchInput(icon: "not-accepted"))
            }) { response in
                #expect(response.status == .badRequest)
            }
            let stored = try #require(try await Study.find(studyID, on: app.db))
            #expect(stored.icon == initial.icon)
            #expect(stored.draftRevision == initial.draftRevision)
        }
    }

    @Test
    func componentEditInvalidatesTheWholeDraft() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let initial = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let studyID = try initial.requireId()
            let tag = "\"\(initial.draftRevision.uuidString)\""
            let input = Components.Schemas.InformationalComponentInput(
                name: "Instructions", data: .init([.enUS: .init(title: "Instructions", content: "Synthetic study instructions.")])
            )
            try await app.test(.POST, "\(apiBasePath)/studies/\(studyID)/components/informational", beforeRequest: { request in
                request.bearerAuth(token)
                request.headers.replaceOrAdd(name: "If-Match", value: tag)
                try request.encodeJSONBody(input)
            }) { response in
                #expect(response.status == .created)
            }
            try await app.test(.PATCH, "\(apiBasePath)/studies/\(studyID)", beforeRequest: { request in
                request.bearerAuth(token)
                request.headers.replaceOrAdd(name: "If-Match", value: tag)
                try request.encodeJSONBody(Components.Schemas.StudyPatchInput(icon: "stale-metadata"))
            }) { response in
                #expect(response.status == .preconditionFailed)
            }
            let stored = try #require(try await Study.find(studyID, on: app.db))
            #expect(stored.icon == initial.icon)
            #expect(stored.draftRevision != initial.draftRevision)
            #expect(try await Component.query(on: app.db).filter(\.$study.$id == studyID).count() == 1)
        }
    }

    @Test
    func unavailableAuditRollsBackHTTPWrite() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let initial = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let studyID = try initial.requireId()
            // Only this test's fresh disposable database is affected.
            try await app.db.schema("audit_events").delete()
            try await app.test(.PATCH, "\(apiBasePath)/studies/\(studyID)", beforeRequest: { request in
                request.bearerAuth(token)
                request.headers.replaceOrAdd(name: "If-Match", value: "\"\(initial.draftRevision.uuidString)\"")
                try request.encodeJSONBody(Components.Schemas.StudyPatchInput(icon: "not-accepted"))
            }) { response in
                #expect(response.status == .internalServerError)
            }
            let stored = try #require(try await Study.find(studyID, on: app.db))
            #expect(stored.icon == initial.icon)
            #expect(stored.draftRevision == initial.draftRevision)
        }
    }
}
