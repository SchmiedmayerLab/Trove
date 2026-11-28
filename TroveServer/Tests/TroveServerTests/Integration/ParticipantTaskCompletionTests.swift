// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import SQLKit
import Testing
import TroveAPIServer
import VaporTesting


@testable import TroveServer


/// The receipt of a completion made while another completion is in flight.
private actor ReceiptBox {
    private(set) var receipt: Components.Schemas.TaskCompletionReceipt?

    func set(_ receipt: Components.Schemas.TaskCompletionReceipt) {
        self.receipt = receipt
    }
}


struct ParticipantTaskCompletionTests {
    private typealias Fixture = TaskCompletionFixture

    @Test
    func completionLeavesRoomForTheEnrollmentClosureVersion() throws {
        let maximum = Int64.max / 2
        #expect(try TaskReceiptTransaction.nextVersion(after: maximum - 1) == maximum)
        #expect(throws: ServerError.self) { try TaskReceiptTransaction.nextVersion(after: maximum) }
    }

    @Test
    func acceptedPeriodPreservesAnAbsentEndAndTheEarlierFiniteEnd() throws {
        let start = Date(timeIntervalSince1970: 0)
        let deadline = start.addingTimeInterval(60)
        let enrollmentEnd = start.addingTimeInterval(30)
        func check(policy: Date?, enrollment: Date?, expected: Date?) throws {
            let window = try TaskAdmission.performanceWindow(opens: start, deadline: policy, enrollmentEnd: enrollment)
            let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(window)) as? [String: Any])
            #expect(window.start == start && window.end == expected)
            #expect(object.keys.contains("start") && object.keys.contains("end") == (expected != nil))
        }
        try check(policy: nil, enrollment: nil, expected: nil)
        try check(policy: deadline, enrollment: nil, expected: deadline)
        try check(policy: nil, enrollment: enrollmentEnd, expected: enrollmentEnd)
        try check(policy: deadline, enrollment: enrollmentEnd, expected: enrollmentEnd)
    }

    @Test
    func completionWindowIsHalfOpenAndOpenEndedWithoutAnEnd() throws {
        let opens = Date(timeIntervalSince1970: 100)
        let cutoff = opens.addingTimeInterval(5)
        try TaskAdmission.checkWindow(opens: opens, cutoff: cutoff, now: opens)
        try TaskAdmission.checkWindow(opens: opens, cutoff: cutoff, now: cutoff.addingTimeInterval(-0.001))
        #expect(throws: ServerError.self) { try TaskAdmission.checkWindow(opens: opens, cutoff: cutoff, now: cutoff) }
        #expect(throws: ServerError.self) { try TaskAdmission.checkWindow(opens: opens, cutoff: nil, now: opens.addingTimeInterval(-1)) }
        try TaskAdmission.checkWindow(opens: opens, cutoff: nil, now: opens.addingTimeInterval(100 * 365 * 86_400))
    }

    /// The occurrence offers only the approved administration languages and carries the published schedule's reminder
    /// setting and reminder time.
    @Test(arguments: [(false, nil), (true, nil), (true, Components.Schemas.ScheduleTime(hour: 7, minute: 45))])
    func occurrenceCarriesApprovedLanguagesAndReminder(notify: Bool, reminder: Components.Schemas.ScheduleTime?) async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher, notify: notify, reminder: reminder)
            #expect(Set(assignment.task.administrationLanguages) == ["en-US", "de"] && assignment.task.notification == notify)
            #expect(assignment.task.reminderTime == reminder)
            // The device verifies the downloaded bundle against the digest of the revision the occurrence pins.
            let owner = try await Fixture.token()
            let bundle = try await app.sendRequest(
                .GET, "\(apiBasePath)/participant/studies/\(assignment.study)/\(assignment.task.revision)/bundle"
            ) { $0.bearerAuth(owner) }
            try #require(bundle.status == .ok)
            #expect(FHIRValidationClient.digest(Data(bundle.body.readableBytesView)) == assignment.task.bundleSha256)
            let studies = try await app.sendRequest(.GET, "\(apiBasePath)/participant/studies") { $0.bearerAuth(owner) }
            let listed = try studies.content.decode([Components.Schemas.PublishedStudyListItem].self)
            #expect(listed.first { $0.studyId == assignment.study.uuidString }?.bundleSha256 == assignment.task.bundleSha256)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let french = try #require(LanguageTag(rawValue: "fr"))
                #expect(await Fixture.refuses(.conflict) {
                    try await app.grove[ConsentService.self].startTaskSession(
                        task: assignment.task.id, tag: "\"\(assignment.task.version)\"", language: french
                    )
                })
                let session = try await Fixture.start(assignment.task, on: app, language: "de")
                _ = try await Fixture.complete(assignment.task.id, session: session, bytes: Fixture.response(for: session), on: app)
                let snapshot = try await app.grove[ConsentService.self].taskPage(
                    enrollmentID: assignment.task.enrollmentId.requireId(), cursor: nil, limit: 100
                )
                let completed = try #require(snapshot.items.first { $0.id == assignment.task.id })
                #expect(completed.notification == notify && completed.reminderTime == reminder)
                #expect(completed.administrationLanguages == assignment.task.administrationLanguages)
            }
        }
    }

    /// Exact replay returns the original receipt; an altered replay and a new command for the same occurrence conflict.
    @Test
    func exactReplayReturnsTheReceiptAndAlteredReplayConflicts() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await Self.checkReplay(assignment, on: app)
            }
        }
    }

    /// A failed audit write rolls back the response, receipt and occurrence change together.
    @Test
    func auditFailureRollsBackTheCompletion() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await Self.checkAuditRollback(assignment, on: app)
            }
        }
    }

    /// Two devices with their own commands and response bytes: one completion is accepted, and the stream shows it.
    @Test
    func twoClientsRacingCompletionProduceOneAcceptedResult() async throws {
        let storage = PublicationStorage()
        try await PublicationWorkflowFixtures.withApp(storageProvider: storage, validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let session = try await Self.raceLanguageSelection(assignment.task, on: app)
                let receipt = try await Self.raceCompletion(assignment.task, session: session, storage: storage, on: app)
                try await Self.checkCompletedStream(assignment, receipt: receipt, session: session, on: app)
            }
        }
    }

    @Test
    func withdrawalWhileStagingCannotAcceptTheCheckedResponse() async throws {
        let storage = PublicationStorage()
        try await PublicationWorkflowFixtures.withApp(storageProvider: storage, validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let session = try await Fixture.start(assignment.task, on: app)
                let bytes = try Fixture.response(for: session)
                let enrollment = try assignment.task.enrollmentId.requireId()
                await storage.afterNextUpload {
                    _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: enrollment)
                }
                #expect(await Fixture.refuses(.conflict) { try await Fixture.complete(assignment.task.id, session: session, bytes: bytes, on: app) })
                #expect(try await Fixture.count("task_completions", on: app) == 0)
                let sql = try #require(app.db as? any SQLDatabase)
                #expect(try await sql.raw("SELECT id FROM stored_artifacts WHERE purpose = 'taskResponse' AND state = 'ready'").all().count == 1)
                #expect(await Fixture.refuses(.conflict) { try await Fixture.complete(assignment.task.id, session: session, bytes: bytes, on: app) })
            }
        }
    }

    /// A due occurrence of revision A is not admitted under consent to revision B; B's own occurrence is.
    @Test
    func revisionAdoptionAdmitsOnlyTheAdoptedRevision() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher, dueOnEnrollment: true)
            try await Fixture.publish(studyID: assignment.study, app: app, researcher: researcher)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await Self.checkRevisionAdoption(assignment, on: app)
            }
        }
    }

    /// The accepted receipt survives a later revision adoption; the completed occurrence keeps its outcome.
    @Test(arguments: [false, true])
    func ownedHTTPCompletionAndForeignReplay(finite: Bool) async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher, finite: finite)
            _ = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: "foreign-participant")
            try await Self.checkOwnedHTTPCompletion(assignment, finite: finite, on: app)
        }
    }

    @Test
    func unknownParticipantCannotReadAnOccurrenceThroughCompletion() async throws {
        try await TestApp.withApp(token: .participant(subject: "other-participant")) { app, bearer in
            _ = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: "other-participant")
            let path = "\(apiBasePath)/participant/tasks/\(String(repeating: "a", count: 64))/completion"
            try await app.test(
                .POST,
                path,
                beforeRequest: { request in
                    request.bearerAuth(bearer)
                    request.headers.replaceOrAdd(name: "If-Match", value: "\"\(UUID().uuidString.lowercased())\"")
                    request.headers.replaceOrAdd(name: "Idempotency-Key", value: UUID().uuidString)
                    request.headers.replaceOrAdd(name: "Content-Type", value: "application/octet-stream")
                    request.body.writeString("{}")
                }
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}


extension ParticipantTaskCompletionTests {
    private static func checkReplay(_ assignment: Fixture.Assignment, on app: Application) async throws {
        let task = assignment.task
        let session = try await Fixture.start(task, on: app)
        #expect(UUID(uuidString: session.consentId) == assignment.consent)
        let bytes = try Fixture.response(for: session)
        let command = UUID()
        let early = try Fixture.response(for: session, authored: "2000-01-01T00:00:00Z")
        #expect(await Fixture.refuses(.unprocessableContent) {
            try await Fixture.complete(task.id, session: session, bytes: early, on: app, command: command)
        })
        let foreignSubject = try QuestionnaireResponseValidationTests.response()
        #expect(await Fixture.refuses(.unprocessableContent) {
            try await Fixture.complete(task.id, session: session, bytes: foreignSubject, on: app, command: command)
        })
        async let first = Fixture.complete(task.id, session: session, bytes: bytes, on: app, command: command)
        async let second = Fixture.complete(task.id, session: session, bytes: bytes, on: app, command: command)
        let (accepted, replayed) = try await (first, second)
        #expect(accepted == replayed)
        #expect(accepted.responseSHA256 == FHIRValidationClient.digest(bytes) && accepted.questionnaireSHA256 == task.sha256)
        #expect(accepted.revision == task.revision && UUID(uuidString: accepted.consentId) == assignment.consent)
        #expect(await Fixture.refuses(.conflict) { try await Fixture.complete(task.id, session: session, bytes: bytes, on: app) })
        #expect(await Fixture.refuses(.conflict) {
            try await Fixture.complete(task.id, session: session, bytes: bytes + Data([32]), on: app, command: command)
        })
        #expect(try await Fixture.complete(task.id, session: session, bytes: bytes, on: app, command: command) == accepted)
        #expect(try await Fixture.count("task_completions", on: app) == 1)
        let sql = try #require(app.db as? any SQLDatabase)
        let retained = try await sql.raw("SELECT id FROM stored_artifacts WHERE purpose = 'taskResponse' AND state = 'retained'").all()
        #expect(retained.count == 1)
    }

    private static func checkAuditRollback(_ assignment: Fixture.Assignment, on app: Application) async throws {
        let task = assignment.task
        let session = try await Fixture.start(task, on: app)
        let bytes = try Fixture.response(for: session)
        let before = try await Fixture.stored(task.id, on: app)
        try await Fixture.failAudit(.taskCompletionAccepted, on: app)
        await #expect(throws: (any Error).self) { try await Fixture.complete(task.id, session: session, bytes: bytes, on: app) }
        #expect(try await Fixture.count("task_completions", on: app) == 0)
        let sql = try #require(app.db as? any SQLDatabase)
        let retained = try await sql.raw("SELECT id FROM stored_artifacts WHERE purpose = 'taskResponse' AND state = 'retained'").all()
        #expect(retained.isEmpty)
        let after = try await Fixture.stored(task.id, on: app)
        #expect(after.version == before.version && after.projection == before.projection)
        let delta = try await app.grove[ConsentService.self].taskPage(
            enrollmentID: task.enrollmentId.requireId(), cursor: assignment.checkpoint, limit: 100
        )
        #expect(delta.items.isEmpty && delta.invalidated.isEmpty)
    }

    /// Two devices ask for different languages at once; one session wins and the other device receives a conflict.
    private static func raceLanguageSelection(_ task: TaskOccurrenceStore.Item, on app: Application) async throws -> Components.Schemas.TaskSession {
        let service = app.grove[ConsentService.self]
        let tag = "\"\(task.version)\""
        let english = try #require(LanguageTag(rawValue: "en-US"))
        let german = try #require(LanguageTag(rawValue: "de"))
        async let firstStart = Fixture.attempt { try await service.startTaskSession(task: task.id, tag: tag, language: english) }
        async let secondStart = Fixture.attempt { try await service.startTaskSession(task: task.id, tag: tag, language: german) }
        let sessions = await [firstStart, secondStart].compactMap { try? $0.get() }
        try #require(sessions.count == 1)
        #expect(try await Fixture.count("task_sessions", on: app) == 1)
        let again = try await service.startTaskSession(
            task: task.id, tag: tag, session: sessions[0].id.requireId(), language: sessions[0].language, startedAt: sessions[0].startedAt
        )
        #expect(again.id == sessions[0].id && again.consentId == sessions[0].consentId)
        return sessions[0]
    }

    /// Device B completes while device A's checked response is being stored, after both passed the first check.
    /// Device A's second transaction then finds B's completion and refuses.
    private static func raceCompletion(
        _ task: TaskOccurrenceStore.Item, session: Components.Schemas.TaskSession, storage: PublicationStorage, on app: Application
    ) async throws -> Components.Schemas.TaskCompletionReceipt {
        let deviceA = try Fixture.response(for: session, identifier: "device-a")
        let deviceB = try Fixture.response(for: session, identifier: "device-b")
        let winner = ReceiptBox()
        await storage.afterNextUpload {
            await winner.set(try await Fixture.complete(task.id, session: session, bytes: deviceB, on: app))
        }
        #expect(await Fixture.refuses(.conflict) { try await Fixture.complete(task.id, session: session, bytes: deviceA, on: app) })
        let receipt = try #require(await winner.receipt)
        #expect(receipt.responseSHA256 == FHIRValidationClient.digest(deviceB) && receipt.language == session.language)
        #expect(try await Fixture.count("task_completions", on: app) == 1)
        let sql = try #require(app.db as? any SQLDatabase)
        let retained = try await sql.raw("SELECT id FROM stored_artifacts WHERE purpose = 'taskResponse' AND state = 'retained'").all()
        #expect(retained.count == 1)
        return receipt
    }

    private static func checkCompletedStream(
        _ assignment: Fixture.Assignment,
        receipt: Components.Schemas.TaskCompletionReceipt,
        session: Components.Schemas.TaskSession,
        on app: Application
    ) async throws {
        let task = assignment.task
        let service = app.grove[ConsentService.self]
        let delta = try await service.taskPage(enrollmentID: task.enrollmentId.requireId(), cursor: assignment.checkpoint, limit: 100)
        let completed = try #require(delta.items.first { $0.id == task.id })
        #expect(completed.state == .completed && completed.resultReferences == [receipt.id] && completed.version > task.version)
        #expect(completed.sha256 == task.sha256 && completed.dueAt == task.dueAt && !delta.invalidated.contains(task.id))
        let snapshot = try await service.taskPage(enrollmentID: task.enrollmentId.requireId(), cursor: nil, limit: 100)
        #expect(snapshot.items.first { $0.id == task.id } == completed)
        #expect(await Fixture.refuses(.conflict) {
            try await service.startTaskSession(task: task.id, tag: "\"\(completed.version)\"", language: session.language)
        })
    }

    private static func checkRevisionAdoption(_ assignment: Fixture.Assignment, on app: Application) async throws {
        let enrollment = try assignment.task.enrollmentId.requireId()
        let service = app.grove[ConsentService.self]
        let owner = try await Fixture.token()
        let nextRevision = assignment.task.revision + 1
        let sessionA = try await Fixture.startHTTPSession(assignment.task, owner: owner, language: "en-US", on: app)
        #expect(UUID(uuidString: sessionA.consentId) == assignment.consent)
        let bytesA = try Fixture.response(for: sessionA)
        let consentB = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: enrollment, on: app, revision: nextRevision).requireID()
        let delta = try await service.taskPage(enrollmentID: enrollment, cursor: assignment.checkpoint, limit: 100)
        let replacement = try #require(delta.items.first { $0.revision == nextRevision && $0.state == .assigned })
        let sessionB = try await Fixture.startHTTPSession(replacement, owner: owner, language: "de", on: app)
        #expect(UUID(uuidString: sessionB.consentId) == consentB && consentB != assignment.consent)
        #expect(await Fixture.refuses(.conflict) { try await Fixture.complete(assignment.task.id, session: sessionA, bytes: bytesA, on: app) })
        #expect(await Fixture.refuses(.conflict) {
            try await service.startTaskSession(task: assignment.task.id, tag: "\"\(assignment.task.version)\"", language: sessionA.language)
        })
        #expect(try await Fixture.count("task_completions", on: app) == 0)
        let receiptB = try await Fixture.complete(replacement.id, session: sessionB, bytes: Fixture.response(for: sessionB), on: app)
        #expect(receiptB.consentId == sessionB.consentId && receiptB.revision == nextRevision)
    }

    private static func checkOwnedHTTPCompletion(_ assignment: Fixture.Assignment, finite: Bool, on app: Application) async throws {
        let owner = try await Fixture.token()
        let session = try await Fixture.startHTTPSession(assignment.task, owner: owner, language: finite ? "de" : "en-US", on: app)
        let bytes = try Fixture.response(for: session)
        let command = UUID()
        func complete(_ bearer: String) async throws -> TestingHTTPResponse {
            try await Fixture.completeHTTP(assignment.task.id, session: session, bytes: bytes, bearer: bearer, command: command, on: app)
        }
        let accepted = try await complete(owner)
        try #require(accepted.status == .ok)
        #expect(accepted.headers.first(name: .cacheControl) == "no-store")
        let receipt = try Fixture.decode(Components.Schemas.TaskCompletionReceipt.self, from: accepted)
        #expect(receipt.taskId == assignment.task.id && receipt.language == session.language)
        #expect(receipt.subjectIdentifier.value == assignment.task.enrollmentId)
        #expect(receipt.consentId == session.consentId && receipt.performanceWindow == session.performanceWindow)
        #expect((receipt.performanceWindow.end != nil) == finite)
        try await adoptNextRevisionKeepingTheOutcome(assignment, receipt: receipt, on: app)
        let replay = try await complete(owner)
        try #require(replay.status == .ok)
        #expect(try Fixture.decode(Components.Schemas.TaskCompletionReceipt.self, from: replay) == receipt)
        #expect(try await Fixture.count("task_completions", on: app) == 1)
        let foreign = try await complete(try await Fixture.token(subject: "foreign-participant"))
        #expect(foreign.status == .notFound)
        #expect(!foreign.body.string.contains(receipt.id))
    }

    private static func adoptNextRevisionKeepingTheOutcome(
        _ assignment: Fixture.Assignment, receipt: Components.Schemas.TaskCompletionReceipt, on app: Application
    ) async throws {
        let replacement = try await PublishedStudyFixtures.createPublishedStudy(
            on: app.db, studyId: assignment.study, revision: assignment.task.revision + 1
        )
        try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            let enrollment = try assignment.task.enrollmentId.requireId()
            _ = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: enrollment, on: app, revision: replacement.revision)
            let snapshot = try await app.grove[ConsentService.self].taskPage(enrollmentID: enrollment, cursor: nil, limit: 100)
            let kept = try #require(snapshot.items.first { $0.id == assignment.task.id })
            #expect(kept.state == .completed && kept.resultReferences == [receipt.id])
        }
    }
}
