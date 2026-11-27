//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import GroveStudyDefinition
import SQLKit
import TroveAPITypes


/// Only constructed inside the transaction holding the enrollment write lock.
struct TaskOccurrenceStore {
    typealias Item = Components.Schemas.ParticipantTaskOccurrence

    let sql: any SQLDatabase
    let database: any Database
    let enrollmentID: UUID
    let enrollment: Enrollment
    var participantID: UUID { enrollment.$participant.id }
    let audit: AuditEvent.Context
    let scope: AuditEvent.Scope

    init(on database: any Database, enrollment: Enrollment, context: AuditEvent.Context, scope: AuditEvent.Scope) throws {
        guard database.inTransaction, let sql = database as? any SQLDatabase else { throw AuditError.transactionRequired }
        self.sql = sql
        self.database = database
        enrollmentID = try enrollment.requireID()
        self.enrollment = enrollment
        audit = context
        self.scope = scope
    }

    static func assignmentWindow(enrollmentID: UUID, from lower: Date, until end: Date) -> SQLQueryString {
        """
        SELECT id FROM task_occurrences WHERE enrollment_id = \(bind: enrollmentID)
        AND due_at >= \(bind: lower) AND due_at < \(bind: end)
        """
    }

    /// Whether the published schedule enables a reminder for its occurrences.
    static func remindsParticipant(_ notifications: StudyDefinition.ComponentSchedule.NotificationsConfig) -> Bool {
        switch notifications {
        case .disabled: false
        case .enabled: true
        }
    }

    func reconcile(now: Date, adoptingRevision: Bool = false) async throws -> Int64 {
        if let base = enrollment.taskClosureBase {
            return base * 2
        }
        var version = try await watermark()
        guard enrollment.withdrawnAt == nil, enrollment.endsAt.map({ now < $0 }) ?? true else {
            // One terminal mutation covers every still-active assignment. Its removal version
            // is the stored base plus the occurrence's last change version, which no longer moves once the enrollment closes.
            guard version <= Int64.max / 2 else { throw ServerError.unexpectedError }
            enrollment.taskClosureBase = version
            try await sql.raw("UPDATE enrollments SET task_closure_base = \(bind: version) WHERE id = \(bind: enrollmentID)").run()
            try await sql.raw(
                """
                UPDATE task_occurrences SET invalidated_at = \(bind: now)
                WHERE enrollment_id = \(bind: enrollmentID) AND invalidated_version IS NULL
                """
            )
                .run()
            if version > 0 { try await record(.tasksInvalidated, occurrence: "enrollment-closure", version: version * 2) }
            return version * 2
        }
        let timeline = try await ConsentCollectionTimeline.load(enrollment: enrollment, on: database, asOf: now)
        guard let adoption = timeline.last?.acceptance else {
            return version
        }
        guard let publication = try await PublishedStudy.find(adoption.publicationID, on: database),
            publication.$study.id == enrollment.$study.id, publication.revision == enrollment.currentRevision
        else {
            throw ConsentCollectionTimeline.inconsistent
        }
        if adoptingRevision && timeline.count > 1 {
            try await invalidate(obsoleteBefore: adoption.publicationID, adoptedAt: adoption.acceptedAt, now: now, version: &version)
        }
        try await assign(
            publication: publication,
            adoption: adoption,
            firstAdoption: timeline.count == 1,
            now: now,
            version: &version
        )
        return version
    }

    func watermark() async throws -> Int64 {
        let row = try await sql.raw(
            """
            SELECT MAX(v) AS version FROM (
                SELECT COALESCE(MAX(assigned_version), 0) AS v FROM task_occurrences WHERE enrollment_id = \(bind: enrollmentID)
                UNION ALL
                SELECT COALESCE(MAX(invalidated_version), 0) AS v FROM task_occurrences WHERE enrollment_id = \(bind: enrollmentID)
            ) versions
            """
        )
            .first()
        guard let row else { throw ServerError.unexpectedError }
        return try row.decode(column: "version", as: Int64.self)
    }

    func record(_ action: AuditEvent.Action, occurrence: String, version: Int64) async throws {
        try await AuditRepository.recordMutation(
            .init(
                context: audit,
                action: action,
                scope: scope,
                target: .init(id: enrollmentID, version: "\(version)/\(occurrence)")
            ),
            on: database
        )
    }

    private func invalidate(obsoleteBefore publication: UUID, adoptedAt: Date, now: Date, version: inout Int64) async throws {
        let rows = try await sql.raw(
            """
            SELECT id FROM task_occurrences WHERE enrollment_id = \(bind: enrollmentID)
                AND invalidated_version IS NULL AND publication_id <> \(bind: publication)
                AND due_at >= \(bind: adoptedAt)
                AND NOT EXISTS (SELECT 1 FROM task_completions c WHERE c.task_id = task_occurrences.id)
                AND NOT EXISTS (SELECT 1 FROM task_failures f WHERE f.task_id = task_occurrences.id)
                AND NOT EXISTS (SELECT 1 FROM task_excusals x WHERE x.task_id = task_occurrences.id)
                ORDER BY assigned_version
            """
        )
            .all()
        for row in rows {
            let id = try row.decode(column: "id", as: String.self)
            guard version < Int64.max / 2 else { throw ServerError.unexpectedError }
            version += 1
            try await sql.raw(
                "UPDATE task_occurrences SET invalidated_version = \(bind: version), invalidated_at = \(bind: now) WHERE id = \(bind: id)"
            )
                .run()
            try await record(.tasksInvalidated, occurrence: id, version: version)
        }
    }

    func assign(
        publication: PublishedStudy,
        adoption: ConsentCollectionTimeline.Acceptance,
        firstAdoption: Bool,
        now: Date,
        version: inout Int64
    ) async throws {
        guard let enrolledAt = enrollment.createdAt,
            let calendar = try? PublishedTaskPlan.calendar(timeZone: publication.collectionPolicy.enrollmentPeriod.timeZone)
        else {
            throw ServerError.conflict("The adopted publication has no executable schedule evidence")
        }
        let today = calendar.startOfDay(for: now)
        let horizon = try TaskRecurrence.dayBoundary(after: Self.assignmentHorizonDays, from: today, calendar: calendar)
        let end = min(enrollment.endsAt ?? horizon, horizon)
        // The first consent can activate today's enrollment-triggered task. A later adoption starts a new window.
        let lower = max(today, firstAdoption ? enrolledAt : adoption.acceptedAt)
        guard lower < end else {
            return
        }
        let rows = try await sql.raw(Self.assignmentWindow(enrollmentID: enrollmentID, from: lower, until: end)).all()
        var known = Set(try rows.map { try $0.decode(column: "id", as: String.self) })
        let enrollmentDay = calendar.startOfDay(for: enrolledAt)
        for plan in publication.taskPlan.schedules.sorted(by: { $0.schedule.id.uuidString < $1.schedule.id.uuidString }) {
            let start = max(lower, plan.eligibleFrom(enrolledAt: enrolledAt, acceptedAt: adoption.acceptedAt, firstAdoption: firstAdoption))
            guard start < end else { continue }
            var dates = try plan.dates(enrolledAt: enrolledAt, from: start, until: end, calendar: calendar)
            // On the first adoption, a one-time occurrence due before `start`, but not before the enrollment day, is
            // assigned while its window is open. The assignment window query does not cover it, so its identity is checked.
            var backdated = false
            if firstAdoption, let due = try plan.oneTimeDue(enrolledAt: enrolledAt, calendar: calendar), due >= enrollmentDay, due < start {
                backdated = true
                dates = [due]
            }
            for due in try dates.map(Self.microseconds) where due < end {
                let id = TaskOccurrenceID.make(
                    enrollment: enrollmentID,
                    publication: adoption.publicationID,
                    schedule: plan.schedule.id,
                    due: due
                )
                guard known.insert(id).inserted else { continue }
                if backdated, !(try await sql.raw("SELECT id FROM task_occurrences WHERE id = \(bind: id)").all()).isEmpty {
                    continue
                }
                guard version < Int64.max / 2 else { throw ServerError.unexpectedError }
                let item = try occurrence(
                    plan, publication: publication, id: id, due: due, version: version + 1, now: now, calendar: calendar, adoption: adoption
                )
                if backdated, let cutoff = item.cutoffAt, cutoff <= now {
                    continue
                }
                version += 1
                try await insert(item)
            }
        }
    }

    private func insert(_ assigned: Item) async throws {
        guard let publicationID = UUID(uuidString: assigned.publicationId) else { throw ServerError.unexpectedError }
        let projection = try Self.encode(assigned)
        let item = try Self.decode(projection)
        try await sql.raw(
            """
            INSERT INTO task_occurrences (id, enrollment_id, publication_id, due_at, cutoff_at, assigned_version, assigned_at, projection)
            VALUES (\(bind: item.id), \(bind: enrollmentID), \(bind: publicationID), \(bind: item.dueAt), \(bind: item.cutoffAt),
                \(bind: item.version), \(bind: item.assignedAt), \(bind: projection))
            """
        )
            .run()
        try await record(.tasksAssigned, occurrence: item.id, version: item.version)
    }

    // All identifiers and timing bounds come from the locked enrollment and its accepted publication.
    // swiftlint:disable:next function_parameter_count
    private func occurrence(
        _ plan: PublishedTaskSchedule,
        publication: PublishedStudy,
        id: String,
        due: Date,
        version: Int64,
        now: Date,
        calendar: Calendar,
        adoption: ConsentCollectionTimeline.Acceptance
    ) throws -> Item {
        let day = calendar.startOfDay(for: due)
        let nextDay = try TaskRecurrence.dayBoundary(after: 1, from: day, calendar: calendar)
        let opens: Date
        let cutoff: Date?
        switch plan.schedule.completionPolicy {
        case .anytime:
            opens = adoption.acceptedAt
            cutoff = enrollment.endsAt
        case .afterStart:
            opens = due
            cutoff = enrollment.endsAt
        case .sameDay:
            opens = day
            cutoff = min(nextDay, enrollment.endsAt ?? nextDay)
        case .duringEvent, .sameDayAfterStart:
            // Schedules have no duration, so an event ends with its day and `duringEvent` equals `sameDayAfterStart`.
            opens = due
            cutoff = min(nextDay, enrollment.endsAt ?? nextDay)
        }
        return Item(
            id: id,
            enrollmentId: enrollmentID.uuidString.lowercased(),
            publicationId: adoption.publicationID.uuidString.lowercased(),
            revision: publication.revision,
            artifactId: publication.artifactID.uuidString.lowercased(),
            bundleSha256: publication.bundleDigest,
            componentId: plan.schedule.componentId.uuidString.lowercased(),
            scheduleId: plan.schedule.id.uuidString.lowercased(),
            sha256: plan.questionnaireSHA256,
            questionnaireCanonical: plan.questionnaireCanonical,
            language: plan.language,
            administrationLanguages: plan.administrationLanguages,
            opensAt: max(opens, adoption.acceptedAt),
            dueAt: due,
            cutoffAt: cutoff,
            timeZone: calendar.timeZone.identifier,
            notification: Self.remindsParticipant(plan.schedule.notifications),
            reminderTime: plan.schedule.notifications.time.map { .init($0) },
            state: .assigned,
            version: version,
            assignedAt: now,
            resultReferences: []
        )
    }
}
