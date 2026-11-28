// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Fluent
import Foundation
import SQLKit
import TroveAPIServer


extension ConsentService {
    private static func expectedVersion(_ tag: String) throws -> Int64 {
        guard let expected = Int64(tag.dropFirst().dropLast()), tag == "\"\(expected)\"", expected > 0 else {
            throw ServerError.preconditionFailed("A strong occurrence version tag is required")
        }
        return expected
    }

    private static func excuse(task: String, expected: Int64, store: TaskOccurrenceStore) async throws -> TaskOccurrenceStore.Item {
        let version = try await TaskReceiptTransaction.nextVersion(after: store.watermark())
        let id = UUID()
        var result: TaskOccurrenceStore.Item?
        do {
            try await TaskOutcomeChange.apply(task: task, expectedVersion: expected, version: version, store: store) { item in
                item.state = .cancelled
                item.statusReason = .excused
                result = item
            }
        } catch let error as ServerError where error.status == .conflict {
            let row = try await store.sql.raw(
                "SELECT assigned_version FROM task_occurrences WHERE id = \(bind: task) AND enrollment_id = \(bind: store.enrollmentID)"
            )
                .first()
            guard try row?.decode(column: "assigned_version", as: Int64.self) == expected else {
                throw ServerError.preconditionFailed("The occurrence version changed")
            }
            throw ServerError.conflict("The occurrence is not open")
        }
        try await store.sql.raw(
            """
            INSERT INTO task_excusals (id, task_id, version, excused_at)
            VALUES (\(bind: id), \(bind: task), \(bind: version), \(bind: TaskClock.now()))
            """
        )
            .run()
        try await AuditRepository.recordMutation(
            .init(context: store.audit, action: .taskExcused, scope: store.scope, target: .init(id: id, version: "\(version)/\(task)")),
            on: store.database
        )
        guard var item = result else { throw ServerError.unexpectedError }
        item.version = version
        try await AuditRepository.recordDisclosureIntent(
            .init(context: store.audit, action: .tasksDisclosure, scope: store.scope, target: .init(id: store.enrollmentID, version: "\(version)")),
            on: store.database
        )
        return item
    }

    private func enrollment(of task: String, study: UUID) async throws -> UUID {
        guard task.utf8.count == 64, task.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let sql = repository.database as? any SQLDatabase,
              let row = try await sql.raw(
                  """
                  SELECT t.enrollment_id FROM task_occurrences t JOIN enrollments e ON e.id = t.enrollment_id
                  WHERE t.id = \(bind: task) AND e.study_id = \(bind: study)
                  """
              )
                  .first()
        else { throw ServerError.notFound("Task not found") }
        return try row.decode(column: "enrollment_id", as: UUID.self)
    }

    /// Cancels an open or missed occurrence with the reason excused. It serializes with completion on the enrollment lock.
    func excuseTask(studyID: UUID, task: String, tag: String) async throws -> TaskOccurrenceStore.Item {
        let actor = try AuthContext.checkIsResearcher()
        _ = try await authorizationService.checkResearcherHasStudyDataAccess(studyID, actor: actor, on: repository.database)
        let expected = try Self.expectedVersion(tag)
        guard !repository.database.inTransaction else { throw AuditError.disclosureInsideTransaction }
        let enrollmentID = try await enrollment(of: task, study: studyID)
        return try await TaskClock.transaction(on: repository.database) { transaction in
            let enrollment = try await self.repository.lockEnrollment(id: enrollmentID, on: transaction)
            guard enrollment.$study.id == studyID, let study = try await Study.find(studyID, on: transaction) else {
                throw ServerError.notFound("Task not found")
            }
            try await self.authorizationService.checkResearcherHasStudyDataAccess(study, actor: actor, on: transaction)
            // A withdrawn or closed enrollment's stream ends with its closure removals; it takes no later outcome.
            guard enrollment.taskClosureBase == nil, enrollment.withdrawnAt == nil, enrollment.endsAt.map({ TaskClock.now() < $0 }) ?? true else {
                throw ServerError.conflict("The enrollment is closed")
            }
            let store = try TaskOccurrenceStore(
                on: transaction,
                enrollment: enrollment,
                context: actor.auditContext,
                scope: .study(studyID: studyID, groupID: study.$group.id)
            )
            return try await Self.excuse(task: task, expected: expected, store: store)
        }
    }
}


extension Controller {
    func excuseStudyTask(_ input: Operations.ExcuseStudyTask.Input) async throws -> Operations.ExcuseStudyTask.Output {
        let item = try await consentService.excuseTask(
            studyID: input.path.studyId.requireId(),
            task: input.path.taskId,
            tag: input.headers.ifMatch
        )
        return .ok(.init(headers: .init(cacheControl: .noStore), body: .json(item)))
    }
}
