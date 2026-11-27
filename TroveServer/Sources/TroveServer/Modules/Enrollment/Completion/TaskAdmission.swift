// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Fluent
import Foundation
import SQLKit
import TroveAPIServer


/// Immutable evidence captured when the device starts answering the assignment, confirmed by the server at the next sync.
struct TaskAdmission: Codable, Equatable, Sendable {
    /// An open assignment, its publication and the instrument it pins.
    struct Assignment {
        let item: TaskOccurrenceStore.Item
        let publication: PublishedStudy
        let instrument: PublishedStudyService.TaskInstrument
    }

    let instrument: PublishedStudyService.TaskInstrument
    let subjectIdentifier: Components.Schemas.TaskSubjectIdentifier
    let window: Components.Schemas.TaskPerformanceWindow
    let assignmentVersion: Int64
    let consentID: UUID
    let language: LanguageTag
    let approvalID: UUID
    /// When the device started the session, within the performance window.
    let startedAt: Date

    static func performanceWindow(opens: Date, deadline: Date?, enrollmentEnd: Date?) throws -> Components.Schemas.TaskPerformanceWindow {
        let end = [deadline, enrollmentEnd].compactMap { $0 }.min()
        guard end.map({ opens < $0 }) ?? true else { throw ServerError.conflict("The task has no open performance window") }
        return .init(start: opens, end: end)
    }

    /// The occurrence's window rules: an exclusive cutoff, and no deadline without one.
    static func checkWindow(opens: Date, cutoff: Date?, now: Date) throws {
        guard TaskWindow(opensAt: opens, cutoffAt: cutoff).admits(now) else {
            throw ServerError.conflict("The task is outside its completion window")
        }
    }

    /// Completed, failed, cancelled and removed occurrences are not open.
    static func assignment(task: String, store: TaskOccurrenceStore) async throws -> Assignment {
        guard
            let row = try await store.sql.raw(
                """
                SELECT publication_id, assigned_version, projection FROM task_occurrences
                WHERE id = \(bind: task) AND enrollment_id = \(bind: store.enrollmentID) AND invalidated_version IS NULL AND invalidated_at IS NULL
                """
            )
                .first()
        else { throw ServerError.conflict("The task is no longer assigned") }
        let data = try row.decode(column: "projection", as: String.self)
        let item = try TaskOccurrenceStore.decode(data)
        guard item.state == .assigned else { throw ServerError.conflict("The task is no longer assigned") }
        let publicationID = try row.decode(column: "publication_id", as: UUID.self)
        let version = try row.decode(column: "assigned_version", as: Int64.self)
        guard item.id == task, UUID(uuidString: item.enrollmentId) == store.enrollmentID,
            version == item.version, UUID(uuidString: item.publicationId) == publicationID,
            let component = UUID(uuidString: item.componentId), let schedule = UUID(uuidString: item.scheduleId),
            let publication = try await PublishedStudy.find(publicationID, on: store.database),
            publication.$study.id == store.enrollment.$study.id, publication.revision == item.revision,
            UUID(uuidString: item.artifactId) == publication.artifactID,
            TaskOccurrenceID.make(enrollment: store.enrollmentID, publication: publicationID, schedule: schedule, due: item.dueAt) == task,
            publication.taskPlan.schedules.contains(where: {
                $0.schedule.id == schedule && $0.schedule.componentId == component && $0.questionnaireSHA256 == item.sha256
                    && $0.language == item.language
            })
        else { throw ConsentCollectionTimeline.inconsistent }
        return Assignment(item: item, publication: publication, instrument: .init(
            studyID: publication.$study.id,
            publicationID: publicationID,
            revision: item.revision,
            artifactID: publication.artifactID,
            componentID: component,
            baseLanguage: item.language,
            sha256: item.sha256
        ))
    }

    /// Checks that a device time lies within the window and at most ``TaskResultEvidence/clockTolerance`` after server time.
    /// The request carrying it may arrive after the window ended.
    static func checkDeviceTime(_ instant: Date, window: Components.Schemas.TaskPerformanceWindow, now: Date) throws {
        try checkWindow(opens: window.start, cutoff: window.end, now: instant)
        guard instant <= now.addingTimeInterval(TaskResultEvidence.clockTolerance) else {
            throw ServerError.conflict("The device time lies too far after server time")
        }
    }

    /// Loads the evidence of a session the device started at `startedAt`; `now` is the server time of the confirmation.
    static func load(task: String, store: TaskOccurrenceStore, language: LanguageTag, startedAt: Date, now: Date) async throws -> Self {
        let assignment = try await assignment(task: task, store: store)
        let (item, publication, instrument) = (assignment.item, assignment.publication, assignment.instrument)
        let window = try performanceWindow(opens: item.opensAt, deadline: item.cutoffAt, enrollmentEnd: store.enrollment.endsAt)
        try checkDeviceTime(startedAt, window: window, now: now)
        let history = try await ConsentCollectionTimeline.load(enrollment: store.enrollment, on: store.database, asOf: now)
        guard let consent = history.last?.acceptance, consent.publicationID == instrument.publicationID,
            consent.revision == item.revision
        else { throw ServerError.conflict("The adopted task revision changed") }
        guard item.administrationLanguages.contains(language.rawValue) else {
            throw ServerError.conflict("The administration language has no publication approval")
        }
        let approval = try TaskLanguageEvidence.approval(
            publication: publication,
            component: instrument.componentID,
            digest: item.sha256,
            language: language
        )
        let subject = try StudyDataIdentifiers(studyID: instrument.studyID).subject(enrollmentID: store.enrollmentID)
        return .init(
            instrument: instrument,
            subjectIdentifier: .init(system: subject.system.rawValue, value: subject.value),
            window: window,
            assignmentVersion: item.version,
            consentID: consent.consentID,
            language: language,
            approvalID: approval,
            startedAt: startedAt
        )
    }
}
