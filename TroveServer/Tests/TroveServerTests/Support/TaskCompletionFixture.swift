// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Fluent
import FluentPostgresDriver
import Foundation
import GroveStudyDefinition
import HTTPTypes
import JWTKit
import OpenAPIRuntime
import SQLKit
import Testing
import TroveAPIServer
import TroveAPITypes
import VaporTesting


@testable import TroveServer


/// A participant's study with one published bilingual Questionnaire and its materialized assignments.
enum TaskCompletionFixture {
    struct Assignment: Sendable {
        let task: TaskOccurrenceStore.Item
        let consent: UUID
        let study: UUID
        let checkpoint: UUID
    }

    static func decode<T: Decodable>(_ type: T.Type, from response: TestingHTTPResponse) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try TroveDateTranscoder().decode(decoder.singleValueContainer().decode(String.self))
        }
        return try decoder.decode(type, from: Data(response.body.readableBytesView))
    }

    static func token(
        subject: String = "test-participant", roles: [String] = [TestApp.participantRole], groups: [String] = []
    ) async throws -> String {
        let keys = JWTKeyCollection()
        await keys.add(hmac: HMACKey(from: TestApp.testSecret), digestAlgorithm: .sha256, kid: "test-key")
        return try await TestApp.signToken(keys: keys, subject: subject, roles: roles, groups: groups)
    }

    static func reader() async throws -> String {
        try await token(
            subject: "researcher-test-user", roles: [TestApp.researcherRole], groups: ["/Test Group/researcher", "/Test Group/data-reader"]
        )
    }

    private static func schedule(
        component: UUID, dueOnEnrollment: Bool, notify: Bool, reminder: Components.Schemas.ScheduleTime?, on app: Application
    ) async throws -> UUID {
        let daily = StudyDefinition.ComponentSchedule.ScheduleDefinition.repeated(.daily(hour: 12), offset: .init(day: 1))
        let definitions: [StudyDefinition.ComponentSchedule.ScheduleDefinition] = dueOnEnrollment ? [.once(.event(.enrollment)), daily] : [daily]
        var ids: [UUID] = []
        for definition in definitions {
            let id = UUID()
            let data = StudyDefinition.ComponentSchedule(
                id: id,
                componentId: component,
                scheduleDefinition: definition,
                completionPolicy: .anytime,
                notifications: notify ? .enabled(thread: .task, time: try reminder.map { try .init($0) }) : .disabled
            )
            try await ComponentSchedule(componentId: component, scheduleData: data).create(on: app.db)
            ids.append(id)
        }
        return ids[0]
    }

    static func assign(
        app: Application,
        researcher: String?,
        finite: Bool = false,
        dueOnEnrollment: Bool = false,
        notify: Bool = false,
        reminder: Components.Schemas.ScheduleTime? = nil
    ) async throws -> Assignment {
        try await ParticipantFixtures.createParticipant(on: app.db)
        let group = try await GroupFixtures.createGroup(on: app.db)
        let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
        if finite { study.enrollmentPeriod.duration = .init(day: 10) }
        study.consent[.enUS] = ConsentContent(title: "Consent", content: PublishedStudyFixtures.requiredConsentMarkdown)
        try await study.save(on: app.db)
        let studyID = try study.requireId()
        let bytes = try QuestionnaireResponseValidationTests.questionnaire()
        let imported = try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(studyID)/components/questionnaire") { request in
            request.bearerAuth(researcher)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(study.draftRevision)\"")
            try request.encodeJSONBody(Components.Schemas.QuestionnaireComponentInput(
                name: "Questionnaire",
                data: .init(questionnaire: String(decoding: bytes, as: UTF8.self)),
                administrationLanguages: ["en-US", "de"]
            ))
        }
        try #require(imported.status == .created)
        let component = try Self.decode(Components.Schemas.QuestionnaireComponentResponse.self, from: imported).id.requireId()
        let schedule = try await Self.schedule(component: component, dueOnEnrollment: dueOnEnrollment, notify: notify, reminder: reminder, on: app)
        for language in ["en-US", "de"] {
            let approval = try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(studyID)/components/\(component)/language-approvals") { request in
                request.bearerAuth(researcher)
                try request.encodeJSONBody(["sha256": FHIRValidationClient.digest(bytes), "language": language])
            }
            try #require(approval.status == .created)
        }
        try await publish(studyID: studyID, app: app, researcher: researcher)
        return try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            let enrollment = try await app.grove[ParticipantEnrollmentService.self].enroll(studyId: studyID, invitationCode: nil)
            let consent = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: enrollment.requireID(), on: app)
            let page = try await app.grove[ConsentService.self].taskPage(enrollmentID: enrollment.requireID(), cursor: nil, limit: 100)
            let task = try #require(page.items.sorted { $0.dueAt < $1.dueAt }.first { $0.scheduleId == schedule.uuidString.lowercased() })
            let checkpoint = try #require(page.checkpoint.flatMap(UUID.init(uuidString:)))
            return try Assignment(task: task, consent: consent.requireID(), study: studyID, checkpoint: checkpoint)
        }
    }

    static func publish(studyID: UUID, app: Application, researcher: String?) async throws {
        let draft = try #require(try await Study.find(studyID, on: app.db))
        let validation = try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(studyID)/draft/validations") { request in
            request.bearerAuth(researcher)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(draft.draftRevision)\"")
        }
        try #require(validation.status == .created)
        let report = try Self.decode(Components.Schemas.StudyDraftValidation.self, from: validation)
        let candidate = try #require(report.candidate)
        let published = try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(studyID)/publish") { request in
            request.bearerAuth(researcher)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(report.draftRevision)\"")
            try request.encodeJSONBody(Components.Schemas.StudyPublicationInput(validationId: candidate.id))
        }
        try #require(published.status == .created)
    }

    static func failAudit(_ action: AuditEvent.Action, on app: Application) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        if app.db is any PostgresDatabase {
            try await sql.raw(
                """
                CREATE TRIGGER reject_task_audit BEFORE INSERT ON audit_events FOR EACH ROW
                WHEN (NEW.action = \(literal: action.rawValue)) EXECUTE FUNCTION trove_reject_audit_mutation()
                """
            )
                .run()
        } else {
            try await sql.raw(
                """
                CREATE TRIGGER reject_task_audit BEFORE INSERT ON audit_events WHEN NEW.action = \(literal: action.rawValue)
                BEGIN SELECT RAISE(ABORT, 'Synthetic audit failure'); END
                """
            )
                .run()
        }
    }

    /// Starts the session in the given language and checks that a second device cannot switch it to another one.
    static func start(_ task: TaskOccurrenceStore.Item, on app: Application, language: String = "en-US") async throws
        -> Components.Schemas.TaskSession {
        let service = app.grove[ConsentService.self]
        let tag = "\"\(task.version)\""
        let session = try await service.startTaskSession(task: task.id, tag: tag, language: try #require(LanguageTag(rawValue: language)))
        let other = try #require(LanguageTag(rawValue: language == "de" ? "en-US" : "de"))
        #expect(await refuses(.conflict) { try await service.startTaskSession(task: task.id, tag: tag, language: other) })
        return session
    }

    static func response(for session: Components.Schemas.TaskSession, authored: String? = nil, identifier: String = "synthetic-1") throws -> Data {
        var json = try #require(JSONSerialization.jsonObject(with: QuestionnaireResponseValidationTests.response()) as? [String: Any])
        json["language"] = session.language.rawValue
        json["identifier"] = ["system": "https://responses.trove.test/id", "value": identifier]
        json["subject"] = [
            "type": "Patient", "identifier": ["system": session.subjectIdentifier.system, "value": session.subjectIdentifier.value]
        ]
        json["authored"] = authored ?? StudyPointExport.timestamp(TaskClock.now())
        return try JSONSerialization.data(withJSONObject: json)
    }

    static func complete(
        _ task: String, session: Components.Schemas.TaskSession, bytes: Data, on app: Application, command: UUID = UUID()
    ) async throws -> Components.Schemas.TaskCompletionReceipt {
        try await app.grove[ConsentService.self].completeTask(
            task: task,
            session: session.id.requireId(),
            command: command,
            body: HTTPBody(bytes),
            publications: app.grove[PublishedStudyService.self]
        )
    }

    static func attempt<Value: Sendable>(_ body: @Sendable () async throws -> Value) async -> Result<Value, any Error> {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }

    /// Whether `body` fails with exactly this server status, so an unexpected 500 does not pass as a refusal.
    static func refuses(_ status: HTTPResponse.Status, _ body: () async throws -> some Any) async -> Bool {
        do {
            _ = try await body()
            return false
        } catch {
            return (error as? TroveServer.ServerError)?.status == status
        }
    }

    static func count(_ table: String, on app: Application) async throws -> Int {
        let sql = try #require(app.db as? any SQLDatabase)
        return try await sql.raw("SELECT id FROM \(unsafeRaw: table)").all().count
    }

    static func stored(_ task: String, on app: Application) async throws -> (version: Int64, projection: String) {
        let sql = try #require(app.db as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT assigned_version, projection FROM task_occurrences WHERE id = \(bind: task)").first())
        return try (row.decode(column: "assigned_version", as: Int64.self), row.decode(column: "projection", as: String.self))
    }
}


extension TaskCompletionFixture {
    static func startHTTPSession(_ task: TaskOccurrenceStore.Item, owner: String, language: String, on app: Application) async throws
        -> Components.Schemas.TaskSession {
        let started = try await app.sendRequest(.POST, "\(apiBasePath)/participant/tasks/\(task.id)/session") { request in
            request.bearerAuth(owner)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(task.version)\"")
            try request.encodeJSONBody(["id": UUID().uuidString, "language": language, "startedAt": TroveDateTranscoder().encode(TaskClock.now())])
        }
        try #require(started.status == .ok)
        return try decode(Components.Schemas.TaskSession.self, from: started)
    }

    // swiftlint:disable:next function_parameter_count
    static func completeHTTP(
        _ task: String, session: Components.Schemas.TaskSession, bytes: Data, bearer: String, command: UUID, on app: Application
    ) async throws -> TestingHTTPResponse {
        try await app.sendRequest(.POST, "\(apiBasePath)/participant/tasks/\(task)/completion") { request in
            request.bearerAuth(bearer)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(session.id.lowercased())\"")
            request.headers.replaceOrAdd(name: "Idempotency-Key", value: command.uuidString)
            request.headers.replaceOrAdd(name: "Content-Type", value: "application/octet-stream")
            request.body.writeBytes(bytes)
        }
    }
}


extension ConsentService {
    /// A session the device starts now with a new ID, as the participant app does.
    func startTaskSession(task: String, tag: String, language: LanguageTag) async throws -> Components.Schemas.TaskSession {
        try await startTaskSession(task: task, tag: tag, session: UUID(), language: language, startedAt: TaskClock.now())
    }

    /// A failure the device reports at the time it happened.
    func failTask(task: String, session: UUID, command: UUID) async throws -> TaskFailureReceipt {
        try await failTask(task: task, session: session, command: command, failedAt: TaskClock.now())
    }
}


extension TaskCompletionFixture {
    /// Follows every continuation of a task stream from `cursor` and returns all items and removals.
    static func drain(_ service: ConsentService, enrollment: UUID, from cursor: UUID?) async throws
        -> (items: [TaskOccurrenceStore.Item], invalidated: [String]) {
        var items: [TaskOccurrenceStore.Item] = []
        var invalidated: [String] = []
        var next = cursor
        while true {
            let page = try await service.taskPage(enrollmentID: enrollment, cursor: next, limit: 100)
            items += page.items
            invalidated += page.invalidated
            guard let continuation = page.nextCursor.flatMap(UUID.init(uuidString:)) else {
                return (items, invalidated)
            }
            next = continuation
        }
    }
}
