//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


struct StudyDataAccessTests {
    @Test(arguments: [
        TestApp.Token.none, .participant(subject: "test-participant"), .researcher(),
        .researcher(groups: ["/Test Group/admin", "/Test Group/audit-reader"]),
        .researcher(groups: ["/Test Group/researcher"]), .researcher(groups: ["/Test Group/data-reader"]),
        .researcher(groups: ["/Test Group/researcher", "/Other Group/data-reader"]),
        .researcher(groups: ["/Other Group/researcher", "/Other Group/data-reader"]),
        .researcher(groups: ["/Test Group/researcher", "//Test Group/data-reader"]),
        .researcher(groups: ["/Test Group/researcher", "/Test Group/data-reader/extra"])
    ])
    func explicitClinicalCapabilityAndMembershipAreRequired(token: TestApp.Token) async throws {
        try await TestApp.withApp(token: token) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await StudyDataFixture.accept(fixture, on: app)
            try await app.test(.GET, "\(apiBasePath)/studies/\(fixture.studyIDs[0])/data", beforeRequest: { $0.bearerAuth(bearer) }) {
                #expect($0.status == (bearer == nil ? .unauthorized : .forbidden))
                #expect(!$0.body.string.contains("bundleBase64"))
            }
            #expect(try await StudyDataFixture.disclosureCount(on: app.db) == 0)
        }
    }

    @Test(arguments: [false, true])
    func auditFailurePreventsDisclosureIncludingEmptyPages(empty: Bool) async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            if !empty { try await StudyDataFixture.accept(fixture, on: app) }
            try await StudyDataFixture.rejectAudit(on: app.db)
            try await app.test(.GET, "\(apiBasePath)/studies/\(fixture.studyIDs[0])/data", beforeRequest: { $0.bearerAuth(bearer) }) {
                #expect($0.status == .internalServerError)
                #expect(!$0.body.string.contains("bundleBase64"))
                #expect(!$0.body.string.contains("Synthetic disclosure insert failure"))
            }
            #expect(try await StudyDataFixture.disclosureCount(on: app.db) == 0)
        }
    }

    @Test(arguments: ["limit=0", "limit=101", "limit=invalid", "before=invalid", "versions=unsupported"])
    func invalidQueryCannotReleaseData(query: String) async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await app.test(.GET, "\(apiBasePath)/studies/\(fixture.studyIDs[0])/data?\(query)", beforeRequest: { $0.bearerAuth(bearer) }) {
                #expect($0.status == .badRequest)
                #expect(!$0.body.string.contains("bundleBase64"))
            }
            #expect(try await StudyDataFixture.disclosureCount(on: app.db) == 0)
        }
    }

    @Test
    func emptyPageStillCommitsAnIntent() async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await app.test(.GET, "\(apiBasePath)/studies/\(fixture.studyIDs[0])/data", beforeRequest: { $0.bearerAuth(bearer) }) {
                #expect($0.status == .ok)
                #expect($0.headers.first(name: .cacheControl) == "no-store")
                let page = try $0.content.decode(Components.Schemas.StudyDataPage.self)
                #expect(page.records.isEmpty && page.nextBefore == nil && page.versions == .current)
                #expect(try await StudyDataFixture.disclosureCount(on: app.db) == 1)
            }
        }
    }
}
