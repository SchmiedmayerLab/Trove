// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Fluent
import Foundation
import SQLKit
import TroveAPITypes


/// One occurrence of the task store, frozen with the state it had at capture.
/// Receipts and session evidence are stored as JSON with Foundation's default date encoding; occurrence projections use
/// the wire's microsecond strings through `TaskOccurrenceStore.decode`.
struct TaskExportMember: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        case ready, completed, failed, cancelled
    }

    struct Window: Codable, Equatable {
        let start: Date
        let end: Date?
    }

    struct Subject: Codable, Equatable {
        let system: String
        let value: String
    }

    /// The accepted result of a completed occurrence.
    struct Completion: Codable, Equatable {
        let id: UUID
        let session: UUID
        let command: UUID
        let consent: UUID
        let responseArtifact: UUID
        let responseDigest: String
        let version: Int64
        let acceptedAt: Date
        let language: String
        let evidenceHashes: [String]
    }

    let occurrence: String
    let participant: UUID
    let enrollment: UUID
    let schedule: UUID
    let instrument: PublishedStudyService.TaskInstrument
    let assignedAt: Date
    let window: Window
    let status: Status
    /// Set only on a cancelled occurrence the study released the participant from.
    let excused: Bool
    let lastModified: Date
    let completion: Completion?
    let identityHash: String

    /// The facts the occurrence was assigned with. A later outcome leaves them unchanged.
    var assignment: [String] {
        [occurrence, participant.uuidString, enrollment.uuidString, identityHash]
    }
}


extension TaskExportMember {
    typealias Item = Components.Schemas.ParticipantTaskOccurrence

    private struct State {
        let status: Status
        let excused: Bool
        let lastModified: Date
        let completion: Completion?
    }

    /// Derives the state of one occurrence row and checks it against every stored copy of its evidence.
    /// - Parameters:
    ///   - row: The occurrence joined with its enrollment and, when present, its session, completion, failure and excusal.
    ///   - enrollment: The locked enrollment of the occurrence.
    init(row: any SQLRow, study: UUID, enrollment record: Enrollment) throws {
        let item = try TaskOccurrenceStore.decode(row.decode(column: "projection", as: String.self))
        occurrence = try row.decode(column: "id", as: String.self)
        enrollment = try row.decode(column: "enrollment_id", as: UUID.self)
        participant = try row.decode(column: "participant_id", as: UUID.self)
        guard let schedule = UUID(uuidString: item.scheduleId), let publication = UUID(uuidString: item.publicationId),
              let artifact = UUID(uuidString: item.artifactId), let component = UUID(uuidString: item.componentId) else {
            throw ServerError.forbidden
        }
        self.schedule = schedule
        instrument = .init(
            studyID: study,
            publicationID: publication,
            revision: item.revision,
            artifactID: artifact,
            componentID: component,
            baseLanguage: item.language,
            sha256: item.sha256
        )
        let assignedAt = try row.decode(column: "assigned_at", as: Date.self)
        self.assignedAt = assignedAt
        let performance = try TaskAdmission.performanceWindow(opens: item.opensAt, deadline: item.cutoffAt, enrollmentEnd: record.endsAt)
        let window = Window(start: performance.start, end: performance.end)
        self.window = window
        let due = try row.decode(column: "due_at", as: Date.self)
        let cutoff = try row.decode(column: "cutoff_at", as: Date?.self)
        guard try record.requireID() == enrollment, record.$study.id == study, record.$participant.id == participant,
              item.id == occurrence, UUID(uuidString: item.enrollmentId) == enrollment,
              try row.decode(column: "assigned_version", as: Int64.self) == item.version, Self.same(assignedAt, item.assignedAt),
              try row.decode(column: "publication_id", as: UUID.self) == publication,
              TaskOccurrenceID.make(enrollment: enrollment, publication: publication, schedule: schedule, due: item.dueAt) == occurrence,
              Self.same(due, item.dueAt), Self.same(cutoff, item.cutoffAt)
        else { throw ServerError.forbidden }
        // The occurrence identity and window; an outcome changes only its state and version.
        identityHash = FHIRValidationClient.digest(Data([
            occurrence, item.publicationId, item.componentId, item.scheduleId, item.sha256, item.language, String(item.revision),
            String(item.opensAt.timeIntervalSinceReferenceDate), String(item.dueAt.timeIntervalSinceReferenceDate),
            item.cutoffAt.map { String($0.timeIntervalSinceReferenceDate) } ?? "none"
        ].joined(separator: "/").utf8))
        let state = try Self.state(row: row, item: item, study: study, assignedAt: assignedAt, window: window)
        status = state.status
        excused = state.excused
        lastModified = state.lastModified
        completion = state.completion
    }

    /// Selects every occurrence of the given enrollments with its outcome rows and its stored assignment and removal times.
    static func rows(study: UUID, subset: SQLQueryString, limit: Int, on sql: any SQLDatabase) async throws -> [any SQLRow] {
        try await sql.raw("""
            SELECT o.id, o.enrollment_id, o.publication_id, o.due_at, o.cutoff_at, o.assigned_version, o.invalidated_version,
                   o.assigned_at, o.invalidated_at, o.projection, e.participant_id, s.id AS session_id, s.evidence,
                   c.id AS completion_id, c.session_id AS completion_session_id, c.command_id, c.receipt, c.response_artifact_id,
                   c.version AS completion_version, f.id AS failure_id, f.session_id AS failure_session_id, f.version AS failure_version,
                   f.receipt AS failure_receipt, x.version AS excusal_version, x.excused_at
            FROM task_occurrences o JOIN enrollments e ON e.id = o.enrollment_id
            LEFT JOIN task_sessions s ON s.task_id = o.id
            LEFT JOIN task_completions c ON c.task_id = o.id
            LEFT JOIN task_failures f ON f.task_id = o.id
            LEFT JOIN task_excusals x ON x.task_id = o.id
            WHERE e.study_id = \(bind: study) AND e.withdrawn_at IS NULL \(subset)
            ORDER BY o.id LIMIT \(bind: limit)
            """)
            .all()
    }

    /// Database timestamps and projections both keep microseconds, but their conversions to `Date` can differ in the last bit.
    private static func same(_ stored: Date?, _ projected: Date?) -> Bool {
        switch (stored, projected) {
        case (nil, nil): true
        case let (stored?, projected?): abs(stored.timeIntervalSince(projected)) <= 0.000_001
        default: false
        }
    }

    static func subject(study: UUID, enrollment: UUID) -> Subject {
        .init(system: "urn:trove:study:" + study.uuidString.lowercased() + ":participants", value: enrollment.uuidString.lowercased())
    }

    /// Server times of different requests can come from different replicas. The change versions order the assignment
    /// before its outcome, so an outcome time earlier than the assignment time is clock skew; lastModified then
    /// states the assignment time.
    private static func changed(at instant: Date, assignedAt: Date) -> Date {
        max(instant, assignedAt)
    }

    private static func state(row: any SQLRow, item: Item, study: UUID, assignedAt: Date, window: Window) throws -> State {
        let invalidated = try row.decode(column: "invalidated_version", as: Int64?.self)
        let removedAt = try row.decode(column: "invalidated_at", as: Date?.self)
        let completed = try row.decode(column: "completion_id", as: UUID?.self) != nil
        let failed = try row.decode(column: "failure_id", as: UUID?.self) != nil
        let excusal = try row.decode(column: "excusal_version", as: Int64?.self)
        // An enrollment closure records a removal time without a version and keeps every outcome.
        guard invalidated == nil || removedAt != nil else { throw ServerError.forbidden }
        if item.state == .completed, item.statusReason == nil, completed, !failed, excusal == nil, invalidated == nil {
            let completion = try Self.completion(row: row, item: item, study: study, window: window)
            let lastModified = changed(at: completion.acceptedAt, assignedAt: assignedAt)
            return .init(status: .completed, excused: false, lastModified: lastModified, completion: completion)
        }
        if item.state == .failed, item.statusReason == nil, item.resultReferences.isEmpty, failed, !completed, excusal == nil,
           invalidated == nil {
            let failedAt = try Self.failure(row: row, item: item, study: study, window: window)
            return .init(status: .failed, excused: false, lastModified: changed(at: failedAt, assignedAt: assignedAt), completion: nil)
        }
        if item.state == .cancelled, item.statusReason == .excused, !completed, !failed, excusal == item.version, invalidated == nil {
            // The excusal sets the projection version, so both name the same change.
            let excusedAt = try row.decode(column: "excused_at", as: Date.self)
            // Cancelling an occurrence whose window already ended cannot remove it from the missed count.
            let excusedInWindow = window.end.map { excusedAt < $0 } ?? true
            return excusedInWindow
                ? .init(status: .cancelled, excused: true, lastModified: changed(at: excusedAt, assignedAt: assignedAt), completion: nil)
                : .init(status: .ready, excused: false, lastModified: assignedAt, completion: nil)
        }
        guard item.state == .assigned, item.statusReason == nil, !completed, !failed, excusal == nil else { throw ServerError.forbidden }
        // A revision adoption removes future assignments with an individual version and records its time.
        guard invalidated != nil, let stoppedAt = removedAt else {
            return .init(status: .ready, excused: false, lastModified: assignedAt, completion: nil)
        }
        // An occurrence whose window ended at or before the adoption was missed, not cancelled.
        let stoppedInWindow = window.end.map { stoppedAt < $0 } ?? true
        return stoppedInWindow
            ? .init(status: .cancelled, excused: false, lastModified: changed(at: stoppedAt, assignedAt: assignedAt), completion: nil)
            : .init(status: .ready, excused: false, lastModified: assignedAt, completion: nil)
    }

    /// The session evidence matches the occurrence it was confirmed for.
    private static func matches(_ admission: TaskAdmission, item: Item, study: UUID, window: Window) -> Bool {
        let instrument = admission.instrument
        return instrument.studyID == study
            && instrument.publicationID.uuidString.lowercased() == item.publicationId && instrument.revision == item.revision
            && instrument.componentID.uuidString.lowercased() == item.componentId
            && instrument.artifactID.uuidString.lowercased() == item.artifactId
            && instrument.baseLanguage == item.language && instrument.sha256 == item.sha256
            && Window(start: admission.window.start, end: admission.window.end) == window
            && admission.assignmentVersion < item.version
    }

    /// The failure time, checked against its stored receipt and the session it ended.
    private static func failure(row: any SQLRow, item: Item, study: UUID, window: Window) throws -> Date {
        let receipt = try JSONDecoder().decode(
            Components.Schemas.TaskFailureReceipt.self, from: Data(row.decode(column: "failure_receipt", as: String.self).utf8)
        )
        let admission = try JSONDecoder().decode(TaskAdmission.self, from: Data(row.decode(column: "evidence", as: String.self).utf8))
        let session = try row.decode(column: "session_id", as: UUID.self)
        guard matches(admission, item: item, study: study, window: window), receipt.failedAt >= admission.startedAt.flooredToSecond,
              try row.decode(column: "failure_session_id", as: UUID.self) == session,
              try row.decode(column: "failure_version", as: Int64.self) == item.version, receipt.version == item.version,
              try UUID(uuidString: receipt.id) == row.decode(column: "failure_id", as: UUID.self),
              UUID(uuidString: receipt.sessionId) == session, receipt.taskId == item.id,
              TaskWindow(opensAt: window.start, cutoffAt: window.end).admits(receipt.failedAt) else { throw ServerError.forbidden }
        return receipt.failedAt
    }

    private static func completion(row: any SQLRow, item: Item, study: UUID, window: Window) throws -> Completion {
        let receipt = try JSONDecoder().decode(
            Components.Schemas.TaskCompletionReceipt.self, from: Data(row.decode(column: "receipt", as: String.self).utf8)
        )
        let admission = try JSONDecoder().decode(TaskAdmission.self, from: Data(row.decode(column: "evidence", as: String.self).utf8))
        let id = try row.decode(column: "completion_id", as: UUID.self)
        let session = try row.decode(column: "session_id", as: UUID.self)
        let version = try row.decode(column: "completion_version", as: Int64.self)
        let subject = subject(study: study, enrollment: try row.decode(column: "enrollment_id", as: UUID.self))
        let instrument = admission.instrument
        let receiptWindow = Window(start: receipt.performanceWindow.start, end: receipt.performanceWindow.end)
        // The authored time decides the window; the server acceptance time may lie before the opening by the clock tolerance
        // and after the cutoff, so it is not checked against the window.
        guard try row.decode(column: "completion_session_id", as: UUID.self) == session, version == item.version,
              item.resultReferences == [id.uuidString.lowercased()], matches(admission, item: item, study: study, window: window),
              receiptWindow == window,
              UUID(uuidString: receipt.id) == id, UUID(uuidString: receipt.sessionId) == session, receipt.taskId == item.id,
              receipt.language == admission.language, UUID(uuidString: receipt.consentId) == admission.consentID,
              receipt.revision == instrument.revision, receipt.questionnaireSHA256 == instrument.sha256,
              receipt.subjectIdentifier.system == subject.system, receipt.subjectIdentifier.value == subject.value,
              admission.subjectIdentifier == receipt.subjectIdentifier else { throw ServerError.forbidden }
        return .init(
            id: id,
            session: session,
            command: try row.decode(column: "command_id", as: UUID.self),
            consent: admission.consentID,
            responseArtifact: try row.decode(column: "response_artifact_id", as: UUID.self),
            responseDigest: receipt.responseSHA256,
            version: version,
            acceptedAt: receipt.acceptedAt,
            language: receipt.language.rawValue,
            evidenceHashes: try ["receipt", "evidence"].map {
                FHIRValidationClient.digest(Data(try row.decode(column: $0, as: String.self).utf8))
            }
        )
    }
}
