//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import FluentPostgresDriver
import Foundation
import SQLKit
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


struct StudyAuditTests {
    private static let reader = TestApp.Token.researcher(groups: ["/Test Group/admin", "/Test Group/audit-reader"])

    private static func fixture(on app: Application) async throws -> (study: UUID, group: UUID) {
        let group = try await GroupFixtures.createGroup(on: app.db)
        let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireID())
        return try (study.requireID(), group.requireID())
    }

    @discardableResult
    private static func append(
        study: UUID, group: UUID?, on database: any Database, id: UUID = UUID(), at: Date = Date()
    ) async throws -> UUID {
        let sql = try #require(database as? any SQLDatabase)
        try await sql.raw("""
            INSERT INTO audit_events (id, occurred_at, actor_issuer, actor_subject, action, scope_kind,
                                      study_id, group_id, target_id, outcome, correlation_id)
            VALUES (\(bind: id), \(bind: at), 'https://identity.example', 'retained-sensitive-actor',
                    'consent.recorded', 'study', \(bind: study), \(bind: group), \(bind: UUID()), 'succeeded', \(bind: UUID()))
            """)
            .run()
        return id
    }

    private static func disclosureCount(on database: any Database) async throws -> Int {
        let sql = try #require(database as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT count(*) AS count FROM audit_events WHERE action='study.audit.disclosure'").first())
        return try row.decode(column: "count", as: Int.self)
    }

    @Test(arguments: [
        TestApp.Token.none, .participant(subject: "participant"),
        .researcher(), .researcher(groups: ["/Test Group/researcher", "/Test Group/audit-reader"]),
        .researcher(groups: ["/Test Group/admin", "/Other Group/audit-reader"]),
        .researcher(groups: ["/Other Group/admin", "/Other Group/audit-reader"]),
        .researcher(groups: ["/Test Group/audit-reader"]),
        .researcher(groups: ["//Test Group/admin", "/Test Group/audit-reader"]),
        .researcher(groups: ["/Test Group/admin", "//Test Group/audit-reader"])
    ])
    func readerCapabilityAndAdministrationAreBothRequired(token: TestApp.Token) async throws {
        try await TestApp.withApp(token: token) { app, bearer in
            let fixture = try await Self.fixture(on: app)
            try await Self.append(study: fixture.study, group: fixture.group, on: app.db)
            try await app.test(.GET, "\(apiBasePath)/studies/\(fixture.study)/audit-events", beforeRequest: { $0.bearerAuth(bearer) }) {
                #expect($0.status == (bearer == nil ? .unauthorized : .forbidden))
                #expect(!$0.body.string.contains("retained-sensitive-actor"))
            }
            #expect(try await Self.disclosureCount(on: app.db) == 0)
        }
    }

    @Test
    func paginationPreservesEqualTimestampBoundariesAndScope() async throws {
        try await TestApp.withApp(token: Self.reader) { app, token in
            let fixture = try await Self.fixture(on: app)
            let ids = try [1, 2, 3].map { try #require(UUID(uuidString: "00000000-0000-4000-8000-00000000000\($0)")) }
            let timestamp = Date(timeIntervalSince1970: 1_750_000_000.123456)
            for id in ids { try await Self.append(study: fixture.study, group: fixture.group, on: app.db, id: id, at: timestamp) }
            try await Self.append(study: UUID(), group: fixture.group, on: app.db)
            try await Self.append(study: fixture.study, group: UUID(), on: app.db)
            try await Self.append(study: fixture.study, group: nil, on: app.db)
            _ = try await app.db.transaction { transaction in
                try await AuditRepository.recordMutation(.init(
                    context: .init(actor: .init(issuer: "source", subject: "private")),
                    action: .sourceRegistered,
                    scope: .participantSource(participantID: UUID(), sourceBindingID: UUID()),
                    target: .init(id: UUID())
                ), on: transaction)
            }
            let path = "\(apiBasePath)/studies/\(fixture.study)/audit-events"
            try await app.test(.GET, path + "?limit=2", beforeRequest: { $0.bearerAuth(token) }) { response in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: .cacheControl) == "no-store")
                let page = try response.content.decode(Components.Schemas.StudyAuditPage.self)
                #expect(page.studyId == fixture.study.uuidString)
                #expect(page.records.map(\.id) == [ids[2].uuidString, ids[1].uuidString])
                #expect(page.nextBefore == ids[1].uuidString)
                #expect(page.records.allSatisfy { $0.action == .consent_recorded && $0.outcome == .succeeded })
                #expect(try await Self.disclosureCount(on: app.db) == 1)
            }
            // A newer append and the first read's intent cannot move the older page boundary.
            try await Self.append(study: fixture.study, group: fixture.group, on: app.db)
            try await app.test(.GET, path + "?limit=2&before=\(ids[1])", beforeRequest: { $0.bearerAuth(token) }) { response in
                #expect(response.status == .ok)
                let page = try response.content.decode(Components.Schemas.StudyAuditPage.self)
                #expect(page.records.map(\.id) == [ids[0].uuidString])
                #expect(page.nextBefore == nil)
            }
            #expect(try await Self.disclosureCount(on: app.db) == 2)
        }
    }

    @Test(arguments: ["0", "-1", "101", "9999999999999999999999999", "invalid"])
    func invalidLimitsCannotReturnHistory(limit: String) async throws {
        try await TestApp.withApp(token: Self.reader) { app, token in
            let fixture = try await Self.fixture(on: app)
            try await app.test(
                .GET,
                "\(apiBasePath)/studies/\(fixture.study)/audit-events?limit=\(limit)",
                beforeRequest: { $0.bearerAuth(token) }
            ) { #expect($0.status == .badRequest) }
            #expect(try await Self.disclosureCount(on: app.db) == 0)
        }
    }

    @Test(arguments: [false, true])
    func unknownAndForeignCursorsAreRejected(foreign: Bool) async throws {
        try await TestApp.withApp(token: Self.reader) { app, token in
            let fixture = try await Self.fixture(on: app)
            let cursor = UUID()
            if foreign { try await Self.append(study: UUID(), group: fixture.group, on: app.db, id: cursor) }
            try await app.test(
                .GET,
                "\(apiBasePath)/studies/\(fixture.study)/audit-events?before=\(cursor)",
                beforeRequest: { $0.bearerAuth(token) }
            ) {
                #expect($0.status == .badRequest)
                #expect(!$0.body.string.contains("retained-sensitive-actor"))
            }
            #expect(try await Self.disclosureCount(on: app.db) == 0)
        }
    }

    @Test
    func failedAuditAppendCannotReleaseAnAlreadyReadPage() async throws {
        try await TestApp.withApp(token: Self.reader) { app, token in
            let fixture = try await Self.fixture(on: app)
            try await Self.append(study: fixture.study, group: fixture.group, on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            if app.db is any PostgresDatabase {
                try await sql.raw("""
                    CREATE TRIGGER reject_audit_read BEFORE INSERT ON audit_events FOR EACH ROW
                    WHEN (NEW.action = 'study.audit.disclosure') EXECUTE FUNCTION trove_reject_audit_mutation()
                    """)
                    .run()
            } else {
                try await sql.raw("""
                    CREATE TRIGGER reject_audit_read BEFORE INSERT ON audit_events WHEN NEW.action = 'study.audit.disclosure'
                    BEGIN SELECT RAISE(ABORT, 'Synthetic audit insert failure'); END
                    """)
                    .run()
            }
            try await app.test(.GET, "\(apiBasePath)/studies/\(fixture.study)/audit-events", beforeRequest: { $0.bearerAuth(token) }) {
                #expect($0.status == .internalServerError)
                #expect(!$0.body.string.contains("retained-sensitive-actor"))
                #expect(!$0.body.string.contains("Synthetic audit insert failure"))
            }
            #expect(try await Self.disclosureCount(on: app.db) == 0)
        }
    }

    @Test
    func emptyPageStillRequiresAudit() async throws {
        try await TestApp.withApp(token: Self.reader) { app, token in
            let fixture = try await Self.fixture(on: app)
            try await app.test(.GET, "\(apiBasePath)/studies/\(fixture.study)/audit-events", beforeRequest: { $0.bearerAuth(token) }) {
                #expect($0.status == .ok)
                let page = try $0.content.decode(Components.Schemas.StudyAuditPage.self)
                #expect(page.records.isEmpty && page.nextBefore == nil)
                #expect(try await Self.disclosureCount(on: app.db) == 1)
            }
        }
    }
}
