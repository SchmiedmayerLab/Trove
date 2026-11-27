// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import SQLKit
import Testing
import TroveAPIServer
import TroveAPITypes
@testable import TroveServer
import VaporTesting


/// Task store exports of occurrences assigned, completed, failed, excused and stopped through the participant and study APIs.
struct FrozenTaskExportTests {
    private typealias Fixture = TaskCompletionFixture

    struct Export {
        let manifest: Components.Schemas.FrozenExport
        let members: [Components.Schemas.FrozenExportMember]
        let data: Data
        let path: String
    }

    private static let groups = ["/Test Group/researcher", "/Test Group/data-reader", "/Test Group/principal-investigator"]

    static func exporter() async throws -> String {
        try await Fixture.token(subject: "researcher-test-user", roles: [TestApp.researcherRole], groups: groups)
    }

    static func create(_ study: UUID, app: Application, bearer: String, request: UUID = UUID()) async throws -> String {
        let created = try await FrozenStudyExportTests.create(study: study, request: request, app: app, bearer: bearer)
        try #require(created.status == .ok)
        return "\(apiBasePath)/studies/\(study)/exports/\(try FrozenStudyExportTests.manifest(created).id)"
    }

    /// Executes a captured export and returns its manifest, index and downloaded bytes.
    static func execute(_ path: String, app: Application, bearer: String) async throws -> Export {
        let executed = try await app.sendRequest(.POST, path + "/execution") { $0.bearerAuth(bearer) }
        try #require(executed.status == .ok)
        let page = try await app.sendRequest(.GET, path + "/records?limit=100") { $0.bearerAuth(bearer) }
        try #require(page.status == .ok)
        let index = try page.content.decode(Components.Schemas.FrozenExportPage.self)
        let download = try await app.sendRequest(.GET, path + "/download") { $0.bearerAuth(bearer) }
        try #require(download.status == .ok)
        let data = Data(download.body.readableBytesView)
        return .init(manifest: try FrozenStudyExportTests.manifest(executed), members: index.members, data: data, path: path)
    }

    private static func submit(
        _ task: TaskOccurrenceStore.Item, identifier: String, owner: String, on app: Application
    ) async throws -> Components.Schemas.TaskCompletionReceipt {
        let session = try await Fixture.startHTTPSession(task, owner: owner, language: "de", on: app)
        let bytes = try Fixture.response(for: session, identifier: identifier)
        let result = try await Fixture.completeHTTP(task.id, session: session, bytes: bytes, bearer: owner, command: UUID(), on: app)
        try #require(result.status == .ok)
        return try Fixture.decode(Components.Schemas.TaskCompletionReceipt.self, from: result)
    }

    private static func tasks(_ assignment: Fixture.Assignment, on app: Application) async throws -> [TaskOccurrenceStore.Item] {
        try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            try await app.grove[ConsentService.self].taskPage(enrollmentID: assignment.task.enrollmentId.requireId(), cursor: nil, limit: 100)
        }
        .items.sorted { $0.dueAt < $1.dueAt }
    }

    private static func status(_ lines: [FrozenStudyExportTests.Line], _ id: String) throws -> String? {
        try FrozenStudyExportTests.task(lines, id: id).resources.first?["status"]?.string
    }

    private static func checkDenied(_ path: String, study: UUID, request: UUID, app: Application, bearer: String) async throws {
        for suffix in ["", "/records", "/download"] {
            try await app.test(.GET, path + suffix, beforeRequest: { $0.bearerAuth(bearer) }) { #expect($0.status == .forbidden) }
        }
        try await app.test(.POST, path + "/execution", beforeRequest: { $0.bearerAuth(bearer) }) { #expect($0.status == .forbidden) }
        let denied = try await FrozenStudyExportTests.create(study: study, request: request, app: app, bearer: bearer)
        #expect(denied.status == .forbidden)
    }

    private static func checkCompleted(
        _ export: Export, assignment: Fixture.Assignment, receipt: Components.Schemas.TaskCompletionReceipt, finite: Bool, on app: Application
    ) async throws {
        let stored = try await Fixture.stored(assignment.task.id, on: app)
        let completed = export.members.filter { $0.taskStatus == .completed }
        #expect(completed.map(\.versions) == [["QuestionnaireResponse/\(receipt.id.lowercased())/_history/\(stored.version)"]])
        let lines = try FrozenStudyExportTests.lines(export.data)
        let line = try FrozenStudyExportTests.task(lines, id: assignment.task.id)
        let task = try #require(line.resources.first)
        let base = "https://studies.trove.test/fhir/studies/" + assignment.study.uuidString.lowercased()
        let activity = base + "/ActivityDefinition/" + assignment.task.componentId + "|" + String(assignment.task.revision)
        #expect(task["instantiatesCanonical"]?.string == activity)
        let plan = base + "/PlanDefinition/" + assignment.study.uuidString.lowercased() + "|" + String(assignment.task.revision)
        #expect(task["input"]?.array?.contains { $0["valueCanonical"]?.string == plan } == true)
        #expect((task["input"]?.array?.first?["valuePeriod"]?["end"] != nil) == finite)
        #expect(line.resources.last?["language"]?.string == "de" && line.resources.last?["partOf"] == nil)
    }

    /// Excuses an occurrence and records the excusal after its window ended, as an excusal of a lapsed occurrence is.
    private static func excuseAfterWindow(_ task: TaskOccurrenceStore.Item, study: UUID, bearer: String, on app: Application) async throws {
        let windowEnd = try #require(task.cutoffAt)
        let excused = try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(study)/tasks/\(task.id)/excusal") { request in
            request.bearerAuth(bearer)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(task.version)\"")
        }
        try #require(excused.status == .ok)
        let sql = try #require(app.db as? any SQLDatabase)
        try await sql.raw("UPDATE task_excusals SET excused_at = \(bind: windowEnd.addingTimeInterval(3600)) WHERE task_id = \(bind: task.id)").run()
    }

    private static func checkExcusals(_ export: Export, lines: [FrozenStudyExportTests.Line], excused: String, lapsed: String) throws {
        let excusal = try #require(try FrozenStudyExportTests.task(lines, id: excused).resources.first)
        #expect(excusal["status"]?.string == "cancelled" && excusal["statusReason"]?["coding"]?.array?.first?["code"]?.string == "excused")
        #expect(export.members.first { $0.bundleId == excused }?.taskStatusReason == .excused)
        let missed = try #require(try FrozenStudyExportTests.task(lines, id: lapsed).resources.first)
        #expect(missed["status"]?.string == "ready" && missed["statusReason"] == nil)
        #expect(missed["lastModified"]?.string == missed["authoredOn"]?.string)
    }

    /// Participant admissions, a frozen export, a later admission, replay and withdrawal.
    @Test(arguments: [false, true])
    func laterAdmissionsLeaveTheSnapshotUnchanged(finite: Bool) async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher, finite: finite)
            let owner = try await Fixture.token()
            let exporter = try await Self.exporter()
            let first = try await Self.submit(assignment.task, identifier: "first", owner: owner, on: app)
            let open = try #require(try await Self.tasks(assignment, on: app).first { $0.state == .assigned })
            let request = UUID()
            let path = try await Self.create(assignment.study, app: app, bearer: exporter, request: request)
            _ = try await Self.submit(open, identifier: "second", owner: owner, on: app)
            let export = try await Self.execute(path, app: app, bearer: exporter)
            try FrozenStudyExportTests.retain(export.data, name: finite ? "http-finite" : "http-open")
            #expect(export.manifest.sha256 == FHIRValidationClient.digest(export.data))
            #expect(export.members.first?.kind == .definitions && export.members.count == export.manifest.recordCount)
            #expect(export.members.first { $0.bundleId == open.id }?.taskStatus == .ready)
            try await Self.checkCompleted(export, assignment: assignment, receipt: first, finite: finite, on: app)
            let again = try await app.sendRequest(.GET, path + "/download") { $0.bearerAuth(exporter) }
            #expect(Data(again.body.readableBytesView) == export.data)
            // A second export of the store states the unchanged occurrences with identical bytes.
            let replay = try await Self.execute(try await Self.create(assignment.study, app: app, bearer: exporter), app: app, bearer: exporter)
            let (lines, replayed) = (try FrozenStudyExportTests.lines(export.data), try FrozenStudyExportTests.lines(replay.data))
            let original = try FrozenStudyExportTests.task(lines, id: assignment.task.id).bytes
            #expect(try FrozenStudyExportTests.task(replayed, id: assignment.task.id).bytes == original)
            #expect(try Self.status(replayed, open.id) == "completed")
            _ = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: assignment.task.enrollmentId.requireId())
            }
            try await Self.checkDenied(path, study: assignment.study, request: request, app: app, bearer: exporter)
        }
    }

    /// An excusal and a later revision adoption cancel occurrences, each at the time it happened.
    @Test
    func excusedAndReplacedOccurrencesAreCancelled() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher, finite: true)
            let exporter = try await Self.exporter()
            let open = try await Self.tasks(assignment, on: app)
            let excusable = try #require(open.last)
            let lapsed = try #require(open.dropLast().last)
            try await Self.excuseAfterWindow(lapsed, study: assignment.study, bearer: exporter, on: app)
            let excused = try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(assignment.study)/tasks/\(excusable.id)/excusal") { request in
                request.bearerAuth(exporter)
                request.headers.replaceOrAdd(name: "If-Match", value: "\"\(excusable.version)\"")
            }
            try #require(excused.status == .ok)
            try await Fixture.publish(studyID: assignment.study, app: app, researcher: researcher)
            _ = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await ClinicalEventStoreTests.acceptConsent(enrollmentID: assignment.task.enrollmentId.requireId(), on: app, revision: 2)
            }
            let export = try await Self.execute(try await Self.create(assignment.study, app: app, bearer: exporter), app: app, bearer: exporter)
            try FrozenStudyExportTests.retain(export.data, name: "http-cancelled")
            let lines = try FrozenStudyExportTests.lines(export.data)
            #expect(export.members.filter { $0.kind == .definitions }.map(\.publicationRevisions) == [[1], [2]])
            try Self.checkExcusals(export, lines: lines, excused: excusable.id, lapsed: lapsed.id)
            let sql = try #require(app.db as? any SQLDatabase)
            let replaced = export.members.filter {
                $0.taskStatus == .cancelled && $0.taskStatusReason == nil && $0.publicationRevisions == [1] && $0.bundleId != lapsed.id
            }
            #expect(!replaced.isEmpty)
            for member in replaced {
                let task = try #require(try FrozenStudyExportTests.task(lines, id: member.bundleId).resources.first)
                let row = try #require(try await sql.raw("SELECT invalidated_at FROM task_occurrences WHERE id = \(bind: member.bundleId)").first())
                let removedAt = try TroveDateTranscoder().encode(try row.decode(column: "invalidated_at", as: Date.self))
                #expect(task["lastModified"]?.string == removedAt && task["statusReason"] == nil)
            }
            #expect(export.members.contains { $0.taskStatus == .ready && $0.publicationRevisions == [2] })
        }
    }

    /// A failed occurrence is exported as failed at its failure time, without a result.
    @Test
    func failedOccurrenceIsExportedAsFailed() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            let owner = try await Fixture.token()
            let session = try await Fixture.startHTTPSession(assignment.task, owner: owner, language: "en-US", on: app)
            let failed = try await app.sendRequest(.POST, "\(apiBasePath)/participant/tasks/\(assignment.task.id)/failure") { request in
                request.bearerAuth(owner)
                request.headers.replaceOrAdd(name: "If-Match", value: "\"\(session.id)\"")
                request.headers.replaceOrAdd(name: "Idempotency-Key", value: UUID().uuidString)
                try request.encodeJSONBody(["failedAt": TroveDateTranscoder().encode(TaskClock.now())])
            }
            try #require(failed.status == .ok)
            let receipt = try Fixture.decode(Components.Schemas.TaskFailureReceipt.self, from: failed)
            let exporter = try await Self.exporter()
            let export = try await Self.execute(try await Self.create(assignment.study, app: app, bearer: exporter), app: app, bearer: exporter)
            try FrozenStudyExportTests.retain(export.data, name: "http-failed")
            let lines = try FrozenStudyExportTests.lines(export.data)
            let line = try FrozenStudyExportTests.task(lines, id: assignment.task.id)
            let task = try #require(line.resources.first)
            #expect(line.resources.count == 1 && task["status"]?.string == "failed" && task["output"] == nil && task["statusReason"] == nil)
            #expect(task["lastModified"]?.string == (try TroveDateTranscoder().encode(receipt.failedAt)))
            let member = try #require(export.members.first { $0.bundleId == assignment.task.id })
            #expect(member.taskStatus == .failed && member.taskStatusReason == nil)
        }
    }

    /// An excusal stamped before the assignment by a skewed replica clock still exports; lastModified then states authoredOn,
    /// and authoredOn is the stored assignment time.
    @Test
    func outcomeTimeBeforeTheAssignmentExportsAtTheAssignmentTime() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            let task = assignment.task
            let exporter = try await Self.exporter()
            let excused = try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(assignment.study)/tasks/\(task.id)/excusal") { request in
                request.bearerAuth(exporter)
                request.headers.replaceOrAdd(name: "If-Match", value: "\"\(task.version)\"")
            }
            try #require(excused.status == .ok)
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(try await sql.raw("SELECT assigned_at FROM task_occurrences WHERE id = \(bind: task.id)").first())
            let assignedAt = try row.decode(column: "assigned_at", as: Date.self)
            try await sql.raw("UPDATE task_excusals SET excused_at = \(bind: assignedAt.addingTimeInterval(-10)) WHERE task_id = \(bind: task.id)").run()
            let export = try await Self.execute(try await Self.create(assignment.study, app: app, bearer: exporter), app: app, bearer: exporter)
            let resource = try #require(try FrozenStudyExportTests.task(FrozenStudyExportTests.lines(export.data), id: task.id).resources.first)
            let authoredOn = try TroveDateTranscoder().encode(assignedAt)
            #expect(resource["status"]?.string == "cancelled" && resource["statusReason"] != nil)
            #expect(resource["authoredOn"]?.string == authoredOn && resource["lastModified"]?.string == authoredOn)
        }
    }

    @Test
    func revokedInvestigatorOrReaderRoleDeniesEveryRead() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            let exporter = try await Self.exporter()
            let path = try await Self.create(assignment.study, app: app, bearer: exporter)
            _ = try await Self.execute(path, app: app, bearer: exporter)
            let sql = try #require(app.db as? any SQLDatabase)
            let disclosures = try await sql.raw("SELECT id FROM audit_events WHERE action = 'study.export.disclosure'").all().count
            for groups in [["/Test Group/researcher", "/Test Group/data-reader"], ["/Test Group/researcher", "/Test Group/principal-investigator"]] {
                let revoked = try await Fixture.token(subject: "researcher-test-user", roles: [TestApp.researcherRole], groups: groups)
                try await Self.checkDenied(path, study: assignment.study, request: UUID(), app: app, bearer: revoked)
            }
            #expect(try await sql.raw("SELECT id FROM audit_events WHERE action = 'study.export.disclosure'").all().count == disclosures)
        }
    }

    @Test
    func changedAcceptedResultDeniesTheExport() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            let exporter = try await Self.exporter()
            _ = try await Self.submit(assignment.task, identifier: "first", owner: try await Fixture.token(), on: app)
            let path = try await Self.create(assignment.study, app: app, bearer: exporter)
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(try await sql.raw("SELECT receipt FROM task_completions").first())
            let receipt = try row.decode(column: "receipt", as: String.self)
            let changed = receipt.replacingOccurrences(of: "\"language\":\"de\"", with: "\"language\":\"en-US\"")
            try #require(changed != receipt)
            try await sql.raw("UPDATE task_completions SET receipt = \(bind: changed)").run()
            try await app.test(.POST, path + "/execution", beforeRequest: { $0.bearerAuth(exporter) }) { #expect($0.status == .forbidden) }
            let denied = try await FrozenStudyExportTests.create(study: assignment.study, request: UUID(), app: app, bearer: exporter)
            #expect(denied.status == .forbidden)
            #expect(try await sql.raw("SELECT id FROM study_export_files").all().isEmpty)
        }
    }
}
