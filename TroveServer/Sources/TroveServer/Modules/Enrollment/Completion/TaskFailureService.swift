// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import SQLKit
import TroveAPIServer


extension ConsentService {
    typealias TaskFailureReceipt = Components.Schemas.TaskFailureReceipt

    /// The receipt of an exact retry, or nil when the session has no failure yet.
    private static func storedFailure(task: String, session: UUID, command: UUID, store: TaskOccurrenceStore) async throws
        -> TaskFailureReceipt? {
        guard let row = try await store.sql.raw(
            "SELECT id, command_id, receipt FROM task_failures WHERE session_id = \(bind: session)"
        )
            .first() else { return nil }
        let receipt = try JSONDecoder().decode(TaskFailureReceipt.self, from: Data(row.decode(column: "receipt", as: String.self).utf8))
        let id = try row.decode(column: "id", as: UUID.self)
        guard UUID(uuidString: receipt.id) == id, receipt.taskId == task, UUID(uuidString: receipt.sessionId) == session else {
            throw ServerError.internalServerError("Stored task failure does not match its session")
        }
        guard try row.decode(column: "command_id", as: UUID.self) == command else {
            throw ServerError.conflict("The task already has a different outcome")
        }
        try await TaskReceiptTransaction.disclose(id, store: store)
        return receipt
    }

    // swiftlint:disable:next function_parameter_count
    private static func recordFailure(
        task: String, session: UUID, command: UUID, admission: TaskAdmission, at failedAt: Date, store: TaskOccurrenceStore
    ) async throws -> TaskFailureReceipt {
        let id = UUID()
        let version = try await TaskReceiptTransaction.nextVersion(after: store.watermark())
        let receipt = TaskFailureReceipt(
            id: id.uuidString.lowercased(),
            taskId: task,
            sessionId: session.uuidString.lowercased(),
            version: version,
            failedAt: failedAt
        )
        let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        try await store.sql.raw(
            """
            INSERT INTO task_failures (id, task_id, session_id, command_id, version, receipt)
            VALUES (\(bind: id), \(bind: task), \(bind: session), \(bind: command), \(bind: version), \(bind: json))
            """
        )
            .run()
        try await TaskOutcomeChange.apply(task: task, expectedVersion: admission.assignmentVersion, version: version, store: store) {
            $0.state = .failed
        }
        try await AuditRepository.recordMutation(
            .init(context: store.audit, action: .taskFailed, scope: store.scope, target: .init(id: id, version: "\(version)/\(task)")),
            on: store.database
        )
        try await TaskReceiptTransaction.disclose(id, store: store)
        return receipt
    }

    /// Records that the participant attempted the occurrence in its session but could not complete it.
    ///
    /// The failure is final and excludes completion and excusal. It is admitted under the same conditions as a completion.
    func failTask(task: String, session: UUID, command: UUID, failedAt: Date) async throws -> TaskFailureReceipt {
        let failedAt = try TaskOccurrenceStore.microseconds(failedAt)
        let owner = try await owner(of: task)
        return try await withTask(owner) { store in
            guard let started = try await TaskReceiptTransaction.session(for: task, store: store) else {
                throw ServerError.preconditionFailed("The session of the task was not confirmed")
            }
            guard started.id == session else { throw ServerError.taskSessionSuperseded }
            if let receipt = try await Self.storedFailure(task: task, session: session, command: command, store: store) {
                return receipt
            }
            let now = TaskClock.now()
            let current = try await TaskAdmission.load(
                task: task, store: store, language: started.evidence.language, startedAt: started.evidence.startedAt, now: now
            )
            guard started.evidence == current else { throw ServerError.conflict("The session evidence changed") }
            // The device time of the attempt decides the window and is recorded as the failure time.
            try TaskAdmission.checkDeviceTime(failedAt, window: current.window, now: now)
            // As for authored times, a whole-second failure time may share the second of the session start.
            guard failedAt >= current.startedAt.flooredToSecond else { throw ServerError.conflict("The failure precedes the session start") }
            return try await Self.recordFailure(task: task, session: session, command: command, admission: current, at: failedAt, store: store)
        }
    }
}


extension Controller {
    func failParticipantTask(_ input: Operations.FailParticipantTask.Input) async throws -> Operations.FailParticipantTask.Output {
        _ = try AuthContext.checkIsParticipant()
        let tag = input.headers.ifMatch
        guard let session = UUID(uuidString: String(tag.dropFirst().dropLast())), tag == "\"\(session.uuidString.lowercased())\"" else {
            throw ServerError.preconditionFailed("A strong task session tag is required")
        }
        guard case .json(let failure) = input.body else { throw ServerError.invalidRequestBody }
        let receipt = try await consentService.failTask(
            task: input.path.taskId,
            session: session,
            command: input.headers.idempotencyKey.requireId(),
            failedAt: failure.failedAt
        )
        return .ok(.init(headers: .init(cacheControl: .noStore), body: .json(receipt)))
    }
}
