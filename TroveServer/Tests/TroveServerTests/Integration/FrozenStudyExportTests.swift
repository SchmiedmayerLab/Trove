// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import FluentPostgresDriver
import Foundation
import SQLKit
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


struct FrozenStudyExportTests {
    private static let groups = ["/Test Group/researcher", "/Test Group/data-reader", "/Test Group/principal-investigator"]

    static func create(
        study: UUID, request: UUID, app: Application, bearer: String?
    ) async throws -> TestingHTTPResponse {
        try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(study)/exports", beforeRequest: { http in
            http.bearerAuth(bearer)
            http.headers.contentType = .json
            let input = Components.Schemas.FrozenExportRequest(requestId: request.uuidString, versions: .current)
            http.body = .init(data: try JSONEncoder().encode(input))
        })
    }

    static func manifest(_ response: TestingHTTPResponse) throws -> Components.Schemas.FrozenExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { source in
            try TroveDateTranscoder().decode(source.singleValueContainer().decode(String.self))
        }
        return try decoder.decode(Components.Schemas.FrozenExport.self, from: Data(response.body.readableBytesView))
    }

    private static func checkRevocation(
        _ original: ValidatedExchangeEvent, fixture: ClinicalEventStoreTests.Fixture, app: Application, bearer: String?, path: String
    ) async throws {
        let study = fixture.studyIDs[0]
        let captured = try await create(study: study, request: UUID(), app: app, bearer: bearer)
        let pending = try Self.manifest(captured)
        try await StudyDataFixture.retract(original, fixture: fixture, on: app)
        let execution = "\(apiBasePath)/studies/\(study)/exports/\(pending.id)/execution"
        try await app.test(.POST, execution, beforeRequest: { $0.bearerAuth(bearer) }) { #expect($0.status == .forbidden) }
        for suffix in ["", "/records", "/download"] {
            try await app.test(.GET, path + suffix, beforeRequest: { $0.bearerAuth(bearer) }) { #expect($0.status == .forbidden) }
        }
    }

    @Test
    func frozenMembershipSurvivesNewEventsAndRetractionDeniesAllReads() async throws {
        try await TestApp.withApp(token: .researcher(groups: Self.groups)) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let original = try await StudyDataFixture.accept(fixture, on: app)
            let study = fixture.studyIDs[0]
            let request = UUID()
            let created = try await Self.create(study: study, request: request, app: app, bearer: bearer)
            try #require(created.status == .ok)
            let job = try Self.manifest(created)
            #expect(job.status == .queued)
            let path = "\(apiBasePath)/studies/\(study)/exports/\(job.id)"
            _ = try await StudyDataFixture.accept(fixture, on: app, sequence: 51, recordID: "new-record")
            let executed = try await app.sendRequest(.POST, path + "/execution", beforeRequest: { $0.bearerAuth(bearer) })
            try #require(executed.status == .ok)
            let ready = try Self.manifest(executed)
            #expect(ready.status == .ready && ready.recordCount == 1 && ready.outputCount == job.outputCount)
            let first = try await app.sendRequest(.GET, path + "/download", beforeRequest: { $0.bearerAuth(bearer) })
            try #require(first.status == .ok)
            let bytes = Data(first.body.readableBytesView)
            #expect(bytes.last == 10 && ready.sha256 == FHIRValidationClient.digest(bytes))
            let retry = try await Self.create(study: study, request: request, app: app, bearer: bearer)
            #expect(try Self.manifest(retry) == ready)
            let second = try await app.sendRequest(.GET, path + "/download", beforeRequest: { $0.bearerAuth(bearer) })
            #expect(Data(second.body.readableBytesView) == bytes)
            let page = try await app.sendRequest(.GET, path + "/records?limit=1", beforeRequest: { $0.bearerAuth(bearer) })
            let index = try page.content.decode(Components.Schemas.FrozenExportPage.self)
            #expect(index.members.count == 1 && index.nextOffset == nil)
            #expect(index.members.first?.sha256 == FHIRValidationClient.digest(Data(bytes.dropLast())))
            #expect(index.members.first?.subjectSystem == "urn:trove:study:" + study.uuidString.lowercased() + ":participants")
            try await Self.checkRevocation(original, fixture: fixture, app: app, bearer: bearer, path: path)
        }
    }

    @Test
    func mandatoryDisclosureAuditRollsBackExecution() async throws {
        try await TestApp.withApp(token: .researcher(groups: Self.groups)) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let study = fixture.studyIDs[0]
            let created = try await Self.create(study: study, request: UUID(), app: app, bearer: bearer)
            let job = try Self.manifest(created)
            let sql = try #require(app.db as? any SQLDatabase)
            if app.db is any PostgresDatabase {
                try await sql.raw("""
                    CREATE TRIGGER reject_export_read BEFORE INSERT ON audit_events FOR EACH ROW
                    WHEN (NEW.action = 'study.export.disclosure') EXECUTE FUNCTION trove_reject_audit_mutation()
                    """)
                    .run()
            } else {
                try await sql.raw("""
                    CREATE TRIGGER reject_export_read BEFORE INSERT ON audit_events WHEN NEW.action = 'study.export.disclosure'
                    BEGIN SELECT RAISE(ABORT, 'Synthetic audit failure'); END
                    """)
                    .run()
            }
            let response = try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(study)/exports/\(job.id)/execution", beforeRequest: {
                $0.bearerAuth(bearer)
            })
            #expect(response.status.code >= 500)
            #expect(try await sql.raw("SELECT id FROM study_export_files").all().isEmpty)
        }
    }

    @Test(arguments: [
        ["/Test Group/admin", "/Test Group/data-reader"],
        ["/Test Group/researcher", "/Test Group/principal-investigator"],
        ["/Test Group/researcher", "/Test Group/data-reader", "/Other Group/principal-investigator"]
    ])
    func clinicalAccessAndInvestigatorApprovalAreStudyScoped(groups: [String]) async throws {
        try await TestApp.withApp(token: .researcher(groups: groups)) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let response = try await Self.create(study: fixture.studyIDs[0], request: UUID(), app: app, bearer: bearer)
            #expect(response.status == .forbidden)
            let sql = try #require(app.db as? any SQLDatabase)
            #expect(try await sql.raw("SELECT id FROM study_export_jobs").all().isEmpty)
        }
    }
}


extension FrozenStudyExportTests {
    struct Line {
        let bytes: Data
        let resources: [StudyProjectionJSON]
    }

    static func lines(_ data: Data) throws -> [Line] {
        try data.split(separator: 10, omittingEmptySubsequences: false).dropLast().map { line in
            let bundle = try StudyProjectionJSON.readResult(Data(line))
            return Line(bytes: Data(line), resources: try #require(bundle["entry"]?.array).compactMap { $0["resource"] })
        }
    }

    static func task(_ lines: [Line], id: String) throws -> Line {
        try #require(lines.first { $0.resources.first?["id"]?.string == id && $0.resources.first?["resourceType"]?.string == "Task" })
    }

    /// Writes exported bytes for external validation when a directory is supplied.
    static func retain(_ data: Data, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["TROVE_EXPORT_EVIDENCE_DIRECTORY"] else {
            return
        }
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".ndjson"))
    }
}
