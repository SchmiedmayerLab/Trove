// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


/// Sessions the device starts offline, confirmed at the next sync, and responses uploaded after the cutoff.
struct ParticipantTaskOfflineSessionTests {
    private typealias Fixture = TaskCompletionFixture

    /// The detail of the refusal `body` throws, or nil when it succeeds.
    private static func detail(_ body: () async throws -> some Any) async -> String? {
        do {
            _ = try await body()
            return nil
        } catch {
            return (error as? ServerError)?.detail
        }
    }

    private static func expectRefusedStarts(_ task: TaskOccurrenceStore.Item, at starts: [Date], on app: Application) async throws {
        let english = try #require(LanguageTag(rawValue: "en-US"))
        for start in starts {
            #expect(await Fixture.refuses(.conflict) {
                try await app.grove[ConsentService.self].startTaskSession(
                    task: task.id, tag: "\"\(task.version)\"", session: UUID(), language: english, startedAt: start
                )
            })
        }
    }

    private static func expectSupersededAfterCompletion(
        _ task: TaskOccurrenceStore.Item, session: Components.Schemas.TaskSession, now: Date, on app: Application
    ) async throws {
        let bytes = try Fixture.response(for: session, authored: StudyPointExport.timestamp(session.startedAt))
        _ = try await Fixture.complete(task.id, session: session, bytes: bytes, on: app)
        let english = try #require(LanguageTag(rawValue: "en-US"))
        let late = await Fixture.attempt {
            try await app.grove[ConsentService.self].startTaskSession(
                task: task.id, tag: "\"\(task.version)\"", session: UUID(), language: english, startedAt: now
            )
        }
        if case .failure(let error) = late {
            #expect((error as? ServerError)?.title == "Task Session Superseded")
        } else {
            Issue.record("A second session was confirmed after the completion")
        }
    }

    /// A session and response made within the window while offline are accepted at a sync after the cutoff. A response
    /// authored after the cutoff, a start after the cutoff and a start ahead of server time are refused.
    @Test
    func offlineSessionAndResponseAreAcceptedAfterTheCutoff() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            let task = try await ParticipantTaskOutcomeTests.sameDayOccurrence(
                like: assignment.task, day: DateComponents(year: 2027, month: 6, day: 15), on: app
            )
            let cutoff = try #require(task.cutoffAt)
            let service = app.grove[ConsentService.self]
            let english = try #require(LanguageTag(rawValue: "en-US"))
            let tag = "\"\(task.version)\""
            let started = cutoff.addingTimeInterval(-600)
            let sync = cutoff.addingTimeInterval(3 * 86_400)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await TaskClock.$now.withValue({ sync }) {
                    try await Self.expectRefusedStarts(task, at: [cutoff, sync.addingTimeInterval(TaskResultEvidence.clockTolerance + 1)], on: app)
                    let id = UUID()
                    let session = try await service.startTaskSession(task: task.id, tag: tag, session: id, language: english, startedAt: started)
                    #expect(session.id == id.uuidString.lowercased() && session.startedAt == started)
                    let replay = try await service.startTaskSession(task: task.id, tag: tag, session: id, language: english, startedAt: started)
                    #expect(replay == session)
                    #expect(await Self.detail {
                        try await service.startTaskSession(
                            task: assignment.task.id, tag: "\"\(assignment.task.version)\"", session: id, language: english, startedAt: sync
                        )
                    } == "The session ID is already in use")
                    let late = try Fixture.response(for: session, authored: StudyPointExport.timestamp(cutoff))
                    #expect(await Fixture.refuses(.unprocessableContent) {
                        try await Fixture.complete(task.id, session: session, bytes: late, on: app)
                    })
                    let authored = cutoff.addingTimeInterval(-60)
                    let bytes = try Fixture.response(for: session, authored: StudyPointExport.timestamp(authored))
                    let receipt = try await Fixture.complete(task.id, session: session, bytes: bytes, on: app)
                    #expect(receipt.acceptedAt == sync && receipt.authored == StudyPointExport.timestamp(authored))
                }
            }
        }
    }

    /// Two devices start the same occurrence offline. The first confirmed session wins; the other device's session and
    /// response are refused as superseded.
    @Test
    func firstConfirmedSessionWinsAndTheOtherIsSuperseded() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            let task = assignment.task
            let owner = try await Fixture.token()
            let first = try await Fixture.startHTTPSession(task, owner: owner, language: "en-US", on: app)
            let second = try await app.sendRequest(.POST, "\(apiBasePath)/participant/tasks/\(task.id)/session") { request in
                request.bearerAuth(owner)
                request.headers.replaceOrAdd(name: "If-Match", value: "\"\(task.version)\"")
                try request.encodeJSONBody(["id": UUID().uuidString, "language": "en-US", "startedAt": first.startedAt.ISO8601Format()])
            }
            #expect(second.status == .conflict && second.body.string.contains("Task Session Superseded"))
            var other = first
            other.id = UUID().uuidString.lowercased()
            let response = try await Fixture.completeHTTP(
                task.id, session: other, bytes: Fixture.response(for: first), bearer: owner, command: UUID(), on: app
            )
            #expect(response.status == .conflict && response.body.string.contains("Task Session Superseded"))
            #expect(try await Fixture.count("task_sessions", on: app) == 1)
            #expect(try await Fixture.count("task_completions", on: app) == 0)
            let accepted = try await Fixture.completeHTTP(
                task.id, session: first, bytes: Fixture.response(for: first), bearer: owner, command: UUID(), on: app
            )
            #expect(accepted.status == .ok)
        }
    }

    /// Device times ahead of server time by more than the tolerance are refused for a window without a deadline; a replay
    /// with another start or language and a failure before the session start are refused; a device that confirms after
    /// another device completed receives the superseded reason.
    @Test
    func deviceTimesAreBoundedAndReplaysMustMatch() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            let task = assignment.task
            #expect(task.cutoffAt == nil)
            let service = app.grove[ConsentService.self]
            let english = try #require(LanguageTag(rawValue: "en-US"))
            let german = try #require(LanguageTag(rawValue: "de"))
            let tag = "\"\(task.version)\""
            let now = TaskClock.now()
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await TaskClock.$now.withValue({ now }) {
                    let ahead = now.addingTimeInterval(TaskResultEvidence.clockTolerance + 1)
                    let skewed = await Fixture.attempt {
                        try await service.startTaskSession(task: task.id, tag: tag, session: UUID(), language: english, startedAt: ahead)
                    }
                    #expect((try? skewed.get()) == nil)
                    if case .failure(let error) = skewed {
                        #expect((error as? ServerError)?.detail == "The device time lies too far after server time")
                    }
                    let id = UUID()
                    let start = now.addingTimeInterval(60)
                    let session = try await service.startTaskSession(task: task.id, tag: tag, session: id, language: english, startedAt: start)
                    for (language, replayed) in [(german, start), (english, start.addingTimeInterval(1))] {
                        #expect(await Self.detail {
                            try await service.startTaskSession(task: task.id, tag: tag, session: id, language: language, startedAt: replayed)
                        } == "The session language, start or assignment changed")
                    }
                    #expect(await Self.detail {
                        try await service.failTask(task: task.id, session: id, command: UUID(), failedAt: now.addingTimeInterval(30))
                    } == "The failure precedes the session start")
                    #expect(await Self.detail {
                        try await service.failTask(task: task.id, session: id, command: UUID(), failedAt: ahead)
                    } == "The device time lies too far after server time")
                    try await Self.expectSupersededAfterCompletion(task, session: session, now: now, on: app)
                }
            }
        }
    }
}
