// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import SQLKit
import Testing
import TroveAPIServer
import TroveAPITypes
import VaporTesting

@testable import TroveServer


struct ParticipantTaskFailureTests {
    private typealias Fixture = TaskCompletionFixture

    private static func fail(_ task: String, session: String, bearer: String, command: UUID, on app: Application) async throws
        -> TestingHTTPResponse {
        try await app.sendRequest(.POST, "\(apiBasePath)/participant/tasks/\(task)/failure") { request in
            request.bearerAuth(bearer)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(session.lowercased())\"")
            request.headers.replaceOrAdd(name: "Idempotency-Key", value: command.uuidString)
            try request.encodeJSONBody(["failedAt": TroveDateTranscoder().encode(TaskClock.now())])
        }
    }

    private static func excuse(_ task: String, study: UUID, version: Int64, on app: Application) async throws -> TestingHTTPResponse {
        let reader = try await Fixture.reader()
        return try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(study)/tasks/\(task)/excusal") { request in
            request.bearerAuth(reader)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(version)\"")
        }
    }

    private static func checkRemoved(
        _ started: TaskOccurrenceStore.Item, session: Components.Schemas.TaskSession, study: UUID, owner: String, on app: Application
    ) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        let removed = try #require(try await sql.raw("SELECT invalidated_version FROM task_occurrences WHERE id = \(bind: started.id)").first())
        #expect(try removed.decode(column: "invalidated_version", as: Int64?.self) != nil)
        let restart = try await app.sendRequest(.POST, "\(apiBasePath)/participant/tasks/\(started.id)/session") { request in
            request.bearerAuth(owner)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(started.version)\"")
            try request.encodeJSONBody(["id": session.id, "language": "en-US", "startedAt": TroveDateTranscoder().encode(session.startedAt)])
        }
        #expect(restart.status == .conflict && restart.body.string.contains("The task is no longer assigned"))
        let completion = try await Fixture.completeHTTP(
            started.id, session: session, bytes: Fixture.response(for: session), bearer: owner, command: UUID(), on: app
        )
        #expect(completion.status == .conflict)
        #expect(try await Self.fail(started.id, session: session.id, bearer: owner, command: UUID(), on: app).status == .conflict)
        #expect(try await Self.excuse(started.id, study: study, version: started.version, on: app).status == .conflict)
        #expect(try await Fixture.count("task_completions", on: app) == 0)
        #expect(try await Fixture.count("task_failures", on: app) == 1)
    }

    /// A failure ends the occurrence: its retry returns the original receipt, and no other outcome follows.
    @Test
    func failureIsFinalAndReplays() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            let task = assignment.task
            let owner = try await Fixture.token()
            let session = try await Fixture.startHTTPSession(task, owner: owner, language: "en-US", on: app)
            let command = UUID()
            let failed = try await Self.fail(task.id, session: session.id, bearer: owner, command: command, on: app)
            try #require(failed.status == .ok)
            #expect(failed.headers.first(name: "Cache-Control") == "no-store")
            let receipt = try Fixture.decode(Components.Schemas.TaskFailureReceipt.self, from: failed)
            #expect(receipt.taskId == task.id && receipt.sessionId == session.id && receipt.version > task.version)
            let replay = try await Self.fail(task.id, session: session.id, bearer: owner, command: command, on: app)
            #expect(try Fixture.decode(Components.Schemas.TaskFailureReceipt.self, from: replay) == receipt)
            #expect(try await Self.fail(task.id, session: session.id, bearer: owner, command: UUID(), on: app).status == .conflict)
            let completion = try await Fixture.completeHTTP(
                task.id, session: session, bytes: Fixture.response(for: session), bearer: owner, command: UUID(), on: app
            )
            #expect(completion.status == .conflict)
            #expect(try await Self.excuse(task.id, study: assignment.study, version: receipt.version, on: app).status == .conflict)
            let stored = try await Fixture.stored(task.id, on: app)
            let item = try TaskOccurrenceStore.decode(stored.projection)
            #expect(stored.version == receipt.version && item.state == .failed && item.statusReason == nil && item.resultReferences.isEmpty)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let delta = try await app.grove[ConsentService.self].taskPage(
                    enrollmentID: task.enrollmentId.requireId(), cursor: assignment.checkpoint, limit: 100
                )
                #expect(delta.items.first { $0.id == task.id } == item && !delta.invalidated.contains(task.id))
            }
            let sql = try #require(app.db as? any SQLDatabase)
            #expect(try await sql.raw("SELECT id FROM audit_events WHERE action = 'task.failed'").all().count == 1)
            #expect(try await Fixture.count("task_failures", on: app) == 1)
            #expect(try await Fixture.count("task_completions", on: app) == 0)
            #expect(try await Fixture.count("task_excusals", on: app) == 0)
        }
    }

    /// A failure needs the started session of the occurrence: the attempt is its evidence.
    @Test
    func failureRequiresTheStartedSession() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            let owner = try await Fixture.token()
            let unstarted = try await Self.fail(assignment.task.id, session: UUID().uuidString, bearer: owner, command: UUID(), on: app)
            #expect(unstarted.status == .preconditionFailed)
            _ = try await Fixture.startHTTPSession(assignment.task, owner: owner, language: "en-US", on: app)
            let other = try await Self.fail(assignment.task.id, session: UUID().uuidString, bearer: owner, command: UUID(), on: app)
            #expect(other.status == .conflict && other.body.string.contains("Task Session Superseded"))
            #expect(try await Fixture.count("task_failures", on: app) == 0)
        }
    }

    /// A revision adoption keeps failed and excused occurrences and removes open future ones. A removed occurrence takes no
    /// session and no outcome, also when its session started before the removal.
    @Test
    func adoptionKeepsOutcomesAndRemovedOccurrencesTakeNone() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            let enrollment = try assignment.task.enrollmentId.requireId()
            let page = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await app.grove[ConsentService.self].taskPage(enrollmentID: enrollment, cursor: nil, limit: 100)
            }
            let open = page.items.filter { $0.scheduleId == assignment.task.scheduleId }.sorted { $0.dueAt < $1.dueAt }
            try #require(open.count >= 3)
            let (failing, excused, started) = (open[0], open[1], open[2])
            let owner = try await Fixture.token()
            let failingSession = try await Fixture.startHTTPSession(failing, owner: owner, language: "en-US", on: app)
            #expect(try await Self.fail(failing.id, session: failingSession.id, bearer: owner, command: UUID(), on: app).status == .ok)
            #expect(try await Self.excuse(excused.id, study: assignment.study, version: excused.version, on: app).status == .ok)
            let session = try await Fixture.startHTTPSession(started, owner: owner, language: "en-US", on: app)
            try await Fixture.publish(studyID: assignment.study, app: app, researcher: researcher)
            let snapshot = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: enrollment, on: app, revision: assignment.task.revision + 1)
                return try await app.grove[ConsentService.self].taskPage(enrollmentID: enrollment, cursor: nil, limit: 100)
            }
            #expect(snapshot.items.first { $0.id == failing.id }?.state == .failed)
            #expect(snapshot.items.first { $0.id == excused.id }?.statusReason == .excused)
            #expect(!snapshot.items.contains { $0.id == started.id })
            try await Self.checkRemoved(started, session: session, study: assignment.study, owner: owner, on: app)
        }
    }

    /// A completed occurrence takes no failure.
    @Test
    func completedOccurrenceCannotFail() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let session = try await Fixture.start(assignment.task, on: app)
                _ = try await Fixture.complete(assignment.task.id, session: session, bytes: Fixture.response(for: session), on: app)
                #expect(await Fixture.refuses(.conflict) {
                    try await app.grove[ConsentService.self].failTask(task: assignment.task.id, session: session.id.requireId(), command: UUID())
                })
            }
            #expect(try await Fixture.count("task_failures", on: app) == 0)
        }
    }

    /// A failed audit write records no failure and leaves the occurrence open for completion.
    @Test
    func failureAuditFailureRollsBack() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            try await Fixture.failAudit(.taskFailed, on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let session = try await Fixture.start(assignment.task, on: app)
                let result = await Fixture.attempt {
                    try await app.grove[ConsentService.self].failTask(task: assignment.task.id, session: session.id.requireId(), command: UUID())
                }
                #expect(throws: (any Error).self) { try result.get() }
                #expect(try await Fixture.count("task_failures", on: app) == 0)
                #expect(try await Fixture.stored(assignment.task.id, on: app).version == assignment.task.version)
                _ = try await Fixture.complete(assignment.task.id, session: session, bytes: Fixture.response(for: session), on: app)
            }
        }
    }
}
