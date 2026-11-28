// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import SQLKit
import TroveAPIServer


struct TaskReceiptTransaction: Sendable {
    typealias Receipt = Components.Schemas.TaskCompletionReceipt

    enum Preparation: Sendable {
        case replay(Receipt)
        case pending(TaskAdmission)
    }

    let task: String
    let sessionID: UUID
    let commandID: UUID
    let digest: String

    static func nextVersion(after version: Int64) throws -> Int64 {
        guard (0..<(Int64.max / 2)).contains(version) else { throw ServerError.unexpectedError }
        return version + 1
    }

    static func session(for task: String, store: TaskOccurrenceStore) async throws -> (id: UUID, evidence: TaskAdmission)? {
        guard let row = try await store.sql.raw("SELECT id, evidence FROM task_sessions WHERE task_id = \(bind: task)").first() else {
            return nil
        }
        let json = try row.decode(column: "evidence", as: String.self)
        return try (row.decode(column: "id", as: UUID.self), JSONDecoder().decode(TaskAdmission.self, from: Data(json.utf8)))
    }

    /// Records the device's session as the occurrence's one session. The device chooses the ID; one that names another
    /// occurrence's session is refused.
    static func confirm(session: UUID, task: String, evidence: TaskAdmission, store: TaskOccurrenceStore) async throws {
        guard try await store.sql.raw("SELECT id FROM task_sessions WHERE id = \(bind: session)").all().isEmpty else {
            throw ServerError.conflict("The session ID is already in use")
        }
        let json = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
        try await store.sql.raw(
            """
            INSERT INTO task_sessions (id, task_id, evidence) VALUES (\(bind: session), \(bind: task), \(bind: json))
            """
        )
            .run()
        try await AuditRepository.recordMutation(
            .init(context: store.audit, action: .taskSessionStarted, scope: store.scope, target: .init(id: session)),
            on: store.database
        )
    }

    static func disclose(_ id: UUID, store: TaskOccurrenceStore, action: AuditEvent.Action = .taskReceiptDisclosure) async throws {
        try await AuditRepository.recordDisclosureIntent(
            .init(context: store.audit, action: action, scope: store.scope, target: .init(id: id)),
            on: store.database
        )
    }

    func prepare(store: TaskOccurrenceStore) async throws -> Preparation {
        guard let session = try await Self.session(for: task, store: store) else {
            throw ServerError.preconditionFailed("The session of the task was not confirmed")
        }
        guard session.id == sessionID else { throw ServerError.taskSessionSuperseded }
        if let row = try await store.sql.raw(
            """
            SELECT command_id, receipt, id FROM task_completions WHERE session_id = \(bind: sessionID)
            """
        )
            .first() {
            let json = try row.decode(column: "receipt", as: String.self)
            let receipt = try JSONDecoder().decode(Receipt.self, from: Data(json.utf8))
            let receiptID = try row.decode(column: "id", as: UUID.self)
            let evidence = session.evidence
            guard UUID(uuidString: receipt.id) == receiptID, receipt.taskId == task, UUID(uuidString: receipt.sessionId) == sessionID,
                  UUID(uuidString: receipt.consentId) == evidence.consentID, receipt.revision == evidence.instrument.revision,
                  receipt.questionnaireSHA256 == evidence.instrument.sha256, receipt.language == evidence.language,
                  receipt.subjectIdentifier == evidence.subjectIdentifier, receipt.performanceWindow == evidence.window else {
                throw ServerError.internalServerError("Stored task receipt does not match its session")
            }
            guard try row.decode(column: "command_id", as: UUID.self) == commandID, receipt.responseSHA256 == digest else {
                throw ServerError.conflict("The task already has a different completion")
            }
            try await Self.disclose(receiptID, store: store)
            return .replay(receipt)
        }
        let current = try await TaskAdmission.load(
            task: task, store: store, language: session.evidence.language, startedAt: session.evidence.startedAt, now: TaskClock.now()
        )
        guard session.evidence == current else { throw ServerError.conflict("The session evidence changed") }
        return .pending(current)
    }

    func commit(
        evidence: TaskAdmission, authored: String, artifact: ArtifactReference, artifacts: ArtifactStore, store: TaskOccurrenceStore
    ) async throws -> Receipt {
        let id = UUID()
        let version = try await Self.nextVersion(after: store.watermark())
        // The response was authored within the window; its upload may arrive after the cutoff while the enrollment is open.
        let now = TaskClock.now()
        guard store.enrollment.endsAt.map({ now < $0 }) ?? true else { throw ServerError.conflict("The enrollment is closed") }
        let receipt = Receipt(
            id: id.uuidString.lowercased(),
            taskId: task,
            sessionId: sessionID.uuidString.lowercased(),
            consentId: evidence.consentID.uuidString.lowercased(),
            revision: evidence.instrument.revision,
            questionnaireSHA256: evidence.instrument.sha256,
            responseSHA256: digest,
            language: evidence.language,
            authored: authored,
            acceptedAt: now,
            performanceWindow: evidence.window,
            subjectIdentifier: evidence.subjectIdentifier
        )
        let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        try await artifacts.retain(artifact, on: store.database, now: now)
        try await store.sql.raw(
            """
            INSERT INTO task_completions (id, task_id, session_id, command_id, response_artifact_id, version, receipt)
            VALUES (\(bind: id), \(bind: task), \(bind: sessionID), \(bind: commandID), \(bind: artifact.id), \(bind: version), \(bind: json))
            """
        )
            .run()
        try await TaskOutcomeChange.apply(
            task: task,
            expectedVersion: evidence.assignmentVersion,
            version: version,
            store: store
        ) { item in
            item.state = .completed
            item.resultReferences = [receipt.id]
        }
        try await AuditRepository.recordMutation(
            .init(context: store.audit, action: .taskCompletionAccepted, scope: store.scope, target: .init(id: id, version: "\(version)/\(task)")),
            on: store.database
        )
        try await Self.disclose(id, store: store)
        return receipt
    }
}
