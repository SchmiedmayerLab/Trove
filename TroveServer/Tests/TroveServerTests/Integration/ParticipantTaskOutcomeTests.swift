// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import SQLKit
import Testing
import TroveAPIServer
import VaporTesting


@testable import TroveServer


/// The status of a request made while another request is in flight.
private actor ExcusalResult {
    private(set) var status: HTTPStatus?

    func set(_ status: HTTPStatus) {
        self.status = status
    }
}


/// A server clock a test can move while a completion is in flight.
private final class MovableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    var now: Date {
        lock.withLock { instant }
    }

    init(_ instant: Date) {
        self.instant = instant
    }

    func move(to instant: Date) {
        lock.withLock { self.instant = instant }
    }
}


struct ParticipantTaskOutcomeTests {
    private typealias Fixture = TaskCompletionFixture

    /// A same-day occurrence on the given civil day in Berlin, shaped like a materialized occurrence of the published schedule.
    ///
    /// The row is inserted directly, so these tests cover the civil-day boundary and admission, not the store's materialization.
    static func sameDayOccurrence(
        like template: TaskOccurrenceStore.Item, day: DateComponents, on app: Application
    ) async throws -> TaskOccurrenceStore.Item {
        let zone = "Europe/Berlin"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        var noon = day
        noon.hour = 12
        let due = try #require(calendar.date(from: noon))
        let opens = calendar.startOfDay(for: due)
        let cutoff = try TaskRecurrence.dayBoundary(after: 1, from: opens, calendar: calendar)
        let sql = try #require(app.db as? any SQLDatabase)
        let enrollment = try template.enrollmentId.requireId()
        let publication = try template.publicationId.requireId()
        let row = try await sql.raw("SELECT MAX(assigned_version) AS v FROM task_occurrences WHERE enrollment_id = \(bind: enrollment)").first()
        let watermark = try #require(row).decode(column: "v", as: Int64.self)
        var item = template
        item.id = try TaskOccurrenceID.make(enrollment: enrollment, publication: publication, schedule: template.scheduleId.requireId(), due: due)
        item.dueAt = due
        item.opensAt = opens
        item.cutoffAt = cutoff
        item.timeZone = zone
        item.version = watermark + 1
        let projection = try TaskOccurrenceStore.encode(item)
        try await sql.raw(
            """
            INSERT INTO task_occurrences (id, enrollment_id, publication_id, due_at, cutoff_at, assigned_version, assigned_at, projection)
            VALUES (\(bind: item.id), \(bind: enrollment), \(bind: publication), \(bind: due), \(bind: cutoff), \(bind: item.version),
                \(bind: item.assignedAt), \(bind: projection))
            """
        )
            .run()
        return item
    }

    @Test
    func groveValidPairStillRequiresScopedSubjectAndAuthoredWithinPerformancePeriod() throws {
        let questionnaire = try QuestionnaireResponseValidationTests.questionnaire()
        let language = try #require(LanguageTag(rawValue: "de"))
        let subject = try StudyDataIdentifiers(studyID: UUID()).subject(enrollmentID: UUID())
        var response = try #require(JSONSerialization.jsonObject(with: QuestionnaireResponseValidationTests.response()) as? [String: Any])
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(60)
        response["subject"] = ["type": "Patient", "identifier": ["system": subject.system.rawValue, "value": subject.value]]
        func check(_ json: [String: Any], cutoff: Date?, now: Date? = nil) throws {
            let bytes = try JSONSerialization.data(withJSONObject: json)
            try #require(
                QuestionnaireResponseValidationService.validateCompletion(questionnaire: questionnaire, response: bytes, language: language)
                    .status == .valid
            )
            try TaskResultEvidence.check(
                bytes, opens: start, cutoff: cutoff, subjectSystem: subject.system.rawValue, subjectValue: subject.value, now: now
            )
        }
        for instant in [start, end.addingTimeInterval(-1)] {
            response["authored"] = StudyPointExport.timestamp(instant)
            try check(response, cutoff: end)
        }
        response["authored"] = StudyPointExport.timestamp(end)
        #expect(throws: ServerError.self) { try check(response, cutoff: end) }
        // The same instant in another offset, and a time far after the start of a window without an end.
        response["authored"] = "2023-11-14T23:13:20+01:00"
        try check(response, cutoff: end)
        response["authored"] = StudyPointExport.timestamp(start.addingTimeInterval(-1))
        #expect(throws: ServerError.self) { try check(response, cutoff: end) }
        response["authored"] = StudyPointExport.timestamp(end.addingTimeInterval(1))
        #expect(throws: ServerError.self) { try check(response, cutoff: end) }
        // A window without an end admits any later authored time up to the clock tolerance after server time.
        let far = start.addingTimeInterval(50 * 365 * 86_400)
        response["authored"] = StudyPointExport.timestamp(far)
        try check(response, cutoff: nil, now: far.addingTimeInterval(-TaskResultEvidence.clockTolerance))
        #expect(throws: ServerError.self) { try check(response, cutoff: nil, now: far.addingTimeInterval(-TaskResultEvidence.clockTolerance - 1)) }
        var modified = response
        modified["modifierExtension"] = [["url": "https://example.org/modifier", "valueBoolean": true]]
        let modifiedBytes = try JSONSerialization.data(withJSONObject: modified)
        #expect(throws: ServerError.self) {
            try TaskResultEvidence.check(
                modifiedBytes, opens: start, cutoff: nil, subjectSystem: subject.system.rawValue, subjectValue: subject.value
            )
        }
        // Bytes that are not a JSON object are refused as invalid output, not as a server error.
        for bytes in [Data(), Data("not json".utf8), Data("{\"resourceType\":".utf8)] {
            #expect {
                try TaskResultEvidence.check(bytes, opens: start, cutoff: nil, subjectSystem: subject.system.rawValue, subjectValue: subject.value)
            } throws: { ($0 as? TroveServer.ServerError)?.status == .unprocessableContent }
        }
        response["authored"] = "2023-11-14T22:14:20.000000000000000001Z"
        #expect(throws: ServerError.self) { try check(response, cutoff: end) }
        response["subject"] = ["reference": "Patient/unrelated"]
        #expect(throws: ServerError.self) { try check(response, cutoff: nil) }
    }

    /// An enrollment end bounds the window: completion is admitted before it, and at the end, also when it passes during
    /// validation, the closed enrollment refuses the completion.
    @Test(arguments: ["before", "during", "at"])
    func finiteWindowCutoff(moment: String) async throws {
        let storage = PublicationStorage()
        try await PublicationWorkflowFixtures.withApp(storageProvider: storage, validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher, finite: true)
            let end = try #require(assignment.task.cutoffAt)
            let clock = MovableClock(moment == "at" ? end : end.addingTimeInterval(-60))
            try await TaskClock.$now.withValue({ clock.now }) {
                try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                    let service = app.grove[ConsentService.self]
                    let english = try #require(LanguageTag(rawValue: "en-US"))
                    if moment == "at" {
                        #expect(await Fixture.refuses(.conflict) {
                            try await service.startTaskSession(task: assignment.task.id, tag: "\"\(assignment.task.version)\"", language: english)
                        })
                        #expect(try await Fixture.count("task_sessions", on: app) == 0)
                        return
                    }
                    let session = try await service.startTaskSession(task: assignment.task.id, tag: "\"\(assignment.task.version)\"", language: english)
                    #expect(session.performanceWindow.end == end)
                    let bytes = try Fixture.response(for: session)
                    if moment == "during" {
                        await storage.afterNextUpload { clock.move(to: end) }
                        #expect(await Fixture.refuses(.conflict) {
                            try await Fixture.complete(assignment.task.id, session: session, bytes: bytes, on: app)
                        })
                        #expect(try await Fixture.count("task_completions", on: app) == 0)
                        return
                    }
                    let receipt = try await Fixture.complete(assignment.task.id, session: session, bytes: bytes, on: app)
                    #expect(receipt.acceptedAt < end && receipt.performanceWindow.end == end)
                }
            }
        }
    }

    /// A same-day cutoff that passes while a response authored before it is validated does not refuse it: the upload may
    /// arrive after the cutoff while the enrollment is open.
    @Test
    func policyCutoffPassingDuringValidationKeepsTheCompletion() async throws {
        let storage = PublicationStorage()
        try await PublicationWorkflowFixtures.withApp(storageProvider: storage, validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            let task = try await Self.sameDayOccurrence(like: assignment.task, day: DateComponents(year: 2027, month: 6, day: 15), on: app)
            let cutoff = try #require(task.cutoffAt)
            let clock = MovableClock(cutoff.addingTimeInterval(-60))
            try await TaskClock.$now.withValue({ clock.now }) {
                try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                    let session = try await Fixture.start(task, on: app)
                    let bytes = try Fixture.response(for: session)
                    await storage.afterNextUpload { clock.move(to: cutoff) }
                    let receipt = try await Fixture.complete(task.id, session: session, bytes: bytes, on: app)
                    #expect(receipt.acceptedAt == cutoff && receipt.performanceWindow.end == cutoff)
                    #expect(try await Fixture.count("task_completions", on: app) == 1)
                }
            }
        }
    }

    /// A same-day policy cutoff refuses a failure at the cutoff: the occurrence is then missed. A failure the device recorded
    /// just before the cutoff is accepted with that time, also when the report arrives after the cutoff.
    @Test
    func failureAtThePolicyCutoffIsRefused() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            let task = try await Self.sameDayOccurrence(like: assignment.task, day: DateComponents(year: 2027, month: 6, day: 15), on: app)
            let cutoff = try #require(task.cutoffAt)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let session = try await TaskClock.$now.withValue({ cutoff.addingTimeInterval(-60) }) { try await Fixture.start(task, on: app) }
                try await TaskClock.$now.withValue({ cutoff }) {
                    #expect(await Fixture.refuses(.conflict) {
                        try await app.grove[ConsentService.self].failTask(task: task.id, session: session.id.requireId(), command: UUID())
                    })
                }
                #expect(try await Fixture.count("task_failures", on: app) == 0)
                #expect(try await Fixture.stored(task.id, on: app).version == task.version)
                let last = cutoff.addingTimeInterval(-0.001)
                let receipt = try await TaskClock.$now.withValue({ cutoff.addingTimeInterval(3600) }) {
                    try await app.grove[ConsentService.self].failTask(task: task.id, session: session.id.requireId(), command: UUID(), failedAt: last)
                }
                #expect(receipt.failedAt == last)
            }
        }
    }

    /// A window without an end has no deadline, so completion is accepted long after its start.
    @Test
    func windowWithoutAnEndAcceptsCompletionAtAnyLaterTime() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            #expect(assignment.task.cutoffAt == nil)
            let later = Date().addingTimeInterval(400 * 86_400)
            try await TaskClock.$now.withValue({ later }) {
                try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                    let session = try await Fixture.start(assignment.task, on: app)
                    #expect(session.performanceWindow.end == nil)
                    let receipt = try await Fixture.complete(assignment.task.id, session: session, bytes: Fixture.response(for: session), on: app)
                    #expect(receipt.acceptedAt == later && receipt.performanceWindow.end == nil)
                }
            }
        }
    }

    /// Same-day windows follow the civil day in the study's time zone: 23 hours in spring, 25 hours in autumn.
    @Test(arguments: [true, false])
    func sameDayWindowOnDaylightSavingDays(spring: Bool) async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            let day = DateComponents(year: 2027, month: spring ? 3 : 10, day: spring ? 28 : 31)
            let task = try await Self.sameDayOccurrence(like: assignment.task, day: day, on: app)
            let cutoff = try #require(task.cutoffAt)
            #expect(cutoff.timeIntervalSince(task.opensAt) == (spring ? 23 : 25) * 3600)
            // A fixed 24-hour day would accept the spring cutoff and refuse the autumn instant 24.5 hours after the start.
            let instants = spring ? [cutoff, cutoff.addingTimeInterval(-60)] : [task.opensAt.addingTimeInterval(24.5 * 3600)]
            let authored = spring ? "2027-03-28T23:59:00+02:00" : "2027-10-31T23:30:00+01:00"
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let service = app.grove[ConsentService.self]
                let german = try #require(LanguageTag(rawValue: "de"))
                for instant in instants {
                    try await TaskClock.$now.withValue({ instant }) {
                        guard instant < cutoff else {
                            #expect(await Fixture.refuses(.conflict) {
                                try await service.startTaskSession(task: task.id, tag: "\"\(task.version)\"", language: german)
                            })
                            return
                        }
                        let session = try await service.startTaskSession(task: task.id, tag: "\"\(task.version)\"", language: german)
                        #expect(session.performanceWindow.start == task.opensAt && session.performanceWindow.end == cutoff)
                        let bytes = try Fixture.response(for: session, authored: authored)
                        let receipt = try await Fixture.complete(task.id, session: session, bytes: bytes, on: app)
                        #expect(receipt.acceptedAt == instant)
                    }
                }
                #expect(try await Fixture.count("task_completions", on: app) == 1)
            }
        }
    }

    @Test(arguments: [ValidationStatus.invalid, .unavailable])
    func responseStructureMustPassTheValidatorEngine(structure: ValidationStatus) async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator(structure: structure)) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let session = try await Fixture.start(assignment.task, on: app)
                await #expect {
                    try await Fixture.complete(assignment.task.id, session: session, bytes: Fixture.response(for: session), on: app)
                } throws: {
                    ($0 as? TroveServer.ServerError)?.status == (structure == .invalid ? .unprocessableContent : .serviceUnavailable)
                }
                #expect(try await Fixture.count("task_completions", on: app) == 0)
                let after = try await Fixture.stored(assignment.task.id, on: app)
                #expect(after.version == assignment.task.version)
            }
        }
    }
}


extension ParticipantTaskOutcomeTests {
    private static func excuse(_ task: TaskOccurrenceStore.Item, study: UUID, version: Int64, bearer: String?, on app: Application) async throws
        -> TestingHTTPResponse {
        try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(study)/tasks/\(task.id)/excusal") { request in
            request.bearerAuth(bearer)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(version)\"")
        }
    }

    @Test
    func excusedOccurrenceStaysInTheStreamAndCannotBeCompleted() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            let task = assignment.task
            let reader = try await Fixture.reader()
            let session = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await Fixture.start(task, on: app)
            }
            let outsider = try await Fixture.token(
                subject: "researcher-test-user", roles: [TestApp.researcherRole], groups: ["/Test Group/researcher"]
            )
            #expect(try await Self.excuse(task, study: assignment.study, version: task.version, bearer: outsider, on: app).status == .forbidden)
            #expect(try await Self.excuse(task, study: UUID(), version: task.version, bearer: reader, on: app).status == .notFound)
            let stale = try await Self.excuse(task, study: assignment.study, version: task.version + 1, bearer: reader, on: app)
            #expect(stale.status == .preconditionFailed)
            let excused = try await Self.excuse(task, study: assignment.study, version: task.version, bearer: reader, on: app)
            try #require(excused.status == .ok)
            let item = try Fixture.decode(TaskOccurrenceStore.Item.self, from: excused)
            #expect(item.state == .cancelled && item.statusReason == .excused && item.version > task.version && item.resultReferences.isEmpty)
            let again = try await Self.excuse(task, study: assignment.study, version: item.version, bearer: reader, on: app)
            #expect(again.status == .conflict)
            let sql = try #require(app.db as? any SQLDatabase)
            let audits = try await sql.raw("SELECT id FROM audit_events WHERE action = 'task.excused'").all()
            #expect(audits.count == 1)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                #expect(await Fixture.refuses(.conflict) {
                    try await Fixture.complete(task.id, session: session, bytes: Fixture.response(for: session), on: app)
                })
                let delta = try await app.grove[ConsentService.self].taskPage(
                    enrollmentID: task.enrollmentId.requireId(), cursor: assignment.checkpoint, limit: 100
                )
                #expect(delta.items.first { $0.id == task.id } == item && !delta.invalidated.contains(task.id))
            }
            #expect(try await Fixture.count("task_completions", on: app) == 0)
        }
    }

    /// An excusal committed while a completion is validated wins; the completion's second transaction then refuses.
    @Test
    func excusalDuringValidationWinsOverTheCompletion() async throws {
        let storage = PublicationStorage()
        try await PublicationWorkflowFixtures.withApp(storageProvider: storage, validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            let task = assignment.task
            let reader = try await Fixture.reader()
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let session = try await Fixture.start(task, on: app)
                let bytes = try Fixture.response(for: session)
                let excusal = ExcusalResult()
                await storage.afterNextUpload {
                    await excusal.set(try await Self.excuse(task, study: assignment.study, version: task.version, bearer: reader, on: app).status)
                }
                #expect(await Fixture.refuses(.conflict) { try await Fixture.complete(task.id, session: session, bytes: bytes, on: app) })
                #expect(await excusal.status == .ok)
            }
            #expect(try await Fixture.count("task_completions", on: app) == 0)
            #expect(try await Fixture.count("task_excusals", on: app) == 1)
            let stored = try await Fixture.stored(task.id, on: app)
            let item = try TaskOccurrenceStore.decode(stored.projection)
            #expect(item.state == .cancelled && item.statusReason == .excused)
        }
    }

    /// A completed occurrence cannot be excused: a stale version is a failed precondition, the current one a conflict.
    @Test
    func completedOccurrenceCannotBeExcused() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            let task = assignment.task
            let reader = try await Fixture.reader()
            let receipt = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let session = try await Fixture.start(task, on: app)
                return try await Fixture.complete(task.id, session: session, bytes: Fixture.response(for: session), on: app)
            }
            let stored = try await Fixture.stored(task.id, on: app)
            let stale = try await Self.excuse(task, study: assignment.study, version: task.version, bearer: reader, on: app)
            let current = try await Self.excuse(task, study: assignment.study, version: stored.version, bearer: reader, on: app)
            #expect(stale.status == .preconditionFailed && current.status == .conflict)
            #expect(try await Fixture.count("task_excusals", on: app) == 0)
            let item = try TaskOccurrenceStore.decode(stored.projection)
            #expect(item.state == .completed && item.resultReferences == [receipt.id])
        }
    }

    @Test
    func excusalAuditFailureRollsBackAndLeavesTheOccurrenceOpen() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            let task = assignment.task
            try await Fixture.failAudit(.taskExcused, on: app)
            let reader = try await Fixture.reader()
            let failed = try await Self.excuse(task, study: assignment.study, version: task.version, bearer: reader, on: app)
            #expect(failed.status.code >= 500)
            #expect(try await Fixture.count("task_excusals", on: app) == 0)
            #expect(try await Fixture.stored(task.id, on: app).version == task.version)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let session = try await Fixture.start(task, on: app)
                _ = try await Fixture.complete(task.id, session: session, bytes: Fixture.response(for: session), on: app)
            }
        }
    }
}
