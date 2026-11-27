// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Fluent
import Foundation
import OpenAPIRuntime
import SQLKit
import TroveAPIServer


extension ConsentService {
    struct TaskOwner: Sendable {
        let task: String
        let enrollment: UUID
        let participant: UUID
        let scope: StudyArtifactScope
        let audit: AuditEvent.Context
    }

    private static func responseBytes(_ body: HTTPBody) async throws -> Data {
        do {
            return try await BoundedRequestBody.collect(body, upTo: FHIRValidationClient.maximumBytes)
        } catch BoundedRequestBody.ReadError.tooLarge {
            throw TaskResultEvidence.tooLarge
        } catch BoundedRequestBody.ReadError.lengthMismatch {
            throw ServerError.badRequest("The task response length does not match the request")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw ServerError(status: .serviceUnavailable, title: "Upload Interrupted", detail: "Retry the unchanged request")
        }
    }

    func owner(of task: String) async throws -> TaskOwner {
        let participant = try await authorizationService.currentParticipantId()
        guard task.utf8.count == 64, let sql = repository.database as? any SQLDatabase,
            let row = try await sql.raw(
                """
                SELECT e.id FROM task_occurrences t JOIN enrollments e ON e.id = t.enrollment_id
                WHERE t.id = \(bind: task) AND e.participant_id = \(bind: participant)
                """
            )
                .first()
        else { throw ServerError.notFound("Task not found") }
        let id = try row.decode(column: "id", as: UUID.self)
        let owned = try await authorizationService.checkParticipantHasEnrollmentAccess(id: id)
        let context = try await verifiedStudyContext(enrollment: owned)
        return .init(task: task, enrollment: id, participant: participant, scope: context.scope, audit: context.audit)
    }

    func withTask<Result: Sendable>(
        _ owner: TaskOwner,
        perform: @escaping @Sendable (TaskOccurrenceStore) async throws -> Result
    ) async throws -> Result {
        guard !repository.database.inTransaction else { throw AuditError.disclosureInsideTransaction }
        return try await TaskClock.transaction(on: repository.database) { transaction in
            let enrollment = try await self.repository.lockEnrollment(id: owner.enrollment, on: transaction)
            guard enrollment.$participant.id == owner.participant, enrollment.$study.id == owner.scope.studyID else {
                throw ServerError.notFound("Task not found")
            }
            guard enrollment.taskClosureBase == nil, enrollment.withdrawnAt == nil, enrollment.endsAt.map({ TaskClock.now() < $0 }) ?? true else {
                throw ServerError.conflict("The enrollment is closed")
            }
            return try await perform(
                TaskOccurrenceStore(
                    on: transaction,
                    enrollment: enrollment,
                    context: owner.audit,
                    scope: .study(studyID: owner.scope.studyID, groupID: owner.scope.groupID)
                )
            )
        }
    }

    /// Confirms the session the device started, possibly offline. The first confirmed session of an occurrence wins.
    func startTaskSession(
        task: String, tag: String, session: UUID, language: LanguageTag, startedAt: Date
    ) async throws -> Components.Schemas.TaskSession {
        let owner = try await owner(of: task)
        let startedAt = try TaskOccurrenceStore.microseconds(startedAt)
        return try await withTask(owner) { store in
            let confirmed = try await TaskReceiptTransaction.session(for: task, store: store)
            if let confirmed, confirmed.id != session {
                throw ServerError.taskSessionSuperseded
            }
            let evidence = try await TaskAdmission.load(
                task: task, store: store, language: language, startedAt: startedAt, now: TaskClock.now()
            )
            guard tag == "\"\(evidence.assignmentVersion)\"" else { throw ServerError.preconditionFailed("The assignment version changed") }
            if let existing = confirmed {
                guard evidence == existing.evidence else { throw ServerError.conflict("The session language, start or assignment changed") }
            } else {
                try await TaskReceiptTransaction.confirm(session: session, task: task, evidence: evidence, store: store)
            }
            try await TaskReceiptTransaction.disclose(session, store: store, action: .taskSessionDisclosure)
            return .init(
                id: session.uuidString.lowercased(),
                taskId: task,
                consentId: evidence.consentID.uuidString.lowercased(),
                language: evidence.language,
                startedAt: evidence.startedAt,
                performanceWindow: evidence.window,
                subjectIdentifier: evidence.subjectIdentifier
            )
        }
    }

    func completeTask(
        task: String,
        session: UUID,
        command: UUID,
        body: HTTPBody,
        publications: PublishedStudyService
    ) async throws -> Components.Schemas.TaskCompletionReceipt {
        let owner = try await owner(of: task)
        let response = try await Self.responseBytes(body)
        let digest = FHIRValidationClient.digest(response)
        let command = TaskReceiptTransaction(task: task, sessionID: session, commandID: command, digest: digest)
        let initial = try await withTask(owner) { try await command.prepare(store: $0) }
        switch initial {
        case .replay(let receipt):
            return receipt
        case .pending(let evidence):
            // The local subject and authored checks run before the archive read and the validator round trip.
            // An authored time may carry only whole seconds, so it must not precede the second of the session start.
            let authored = try TaskResultEvidence.check(
                response,
                opens: max(evidence.window.start, evidence.startedAt.flooredToSecond),
                cutoff: evidence.window.end,
                subjectSystem: evidence.subjectIdentifier.system,
                subjectValue: evidence.subjectIdentifier.value,
                now: TaskClock.now()
            )
            let check = try await publications.checkTaskResponse(
                instrument: evidence.instrument,
                sessionLanguage: evidence.language,
                response: response
            )
            guard check.status == .valid, check.questionnaireSHA256 == evidence.instrument.sha256, check.responseSHA256 == digest else {
                throw ServerError(
                    status: .unprocessableContent,
                    title: "Invalid task response",
                    detail: "The response did not pass the task checks"
                )
            }
            let artifacts = ArtifactStore(database: repository.database, storage: storageService)
            let artifact = try await artifacts.stage(
                response, purpose: .taskResponse, ownerID: owner.enrollment, scope: owner.scope, now: TaskClock.now()
            )
            return try await withTask(owner) { store in
                switch try await command.prepare(store: store) {
                case .replay(let receipt): return receipt
                case .pending(let current):
                    guard current == evidence, artifact.digest == digest else {
                        throw ServerError.conflict("The task changed during validation")
                    }
                    return try await command.commit(
                        evidence: current, authored: authored, artifact: artifact, artifacts: artifacts, store: store
                    )
                }
            }
        }
    }
}
