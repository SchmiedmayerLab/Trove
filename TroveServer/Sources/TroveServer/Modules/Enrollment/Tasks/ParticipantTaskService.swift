//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import SQLKit
import TroveAPIServer


extension ConsentService {
    func taskPage(enrollmentID: UUID, cursor: UUID?, limit: Int) async throws -> Components.Schemas.ParticipantTaskPage {
        let owner = try await authorizationService.checkParticipantHasEnrollmentAccess(id: enrollmentID)
        guard (1...100).contains(limit) else { throw ServerError.badRequest("Invalid task page size") }
        let context = try await verifiedStudyContext(enrollment: owner)
        return try await repository.database.transaction { transaction in
            let enrollment = try await self.repository.lockEnrollment(id: enrollmentID, on: transaction)
            guard enrollment.$participant.id == owner.$participant.id, enrollment.$study.id == context.scope.studyID else {
                throw ServerError.notFound("Enrollment not found")
            }
            let now = Date()
            let store = try TaskOccurrenceStore(
                on: transaction,
                enrollment: enrollment,
                context: context.audit,
                scope: .study(studyID: context.scope.studyID, groupID: context.scope.groupID)
            )
            let active = enrollment.withdrawnAt == nil && (enrollment.endsAt.map { now < $0 } ?? true)
            let position = try await store.position(cursor: cursor, active: active, now: now)
            let version: Int64
            if let upper = position.upper { version = upper } else { version = try await store.reconcile(now: now) }
            let page = try await store.page(position, watermark: version, limit: limit, active: active, now: now)
            try await AuditRepository.recordDisclosureIntent(
                .init(
                    context: context.audit,
                    action: .tasksDisclosure,
                    scope: store.scope,
                    target: .init(id: enrollmentID, version: String(page.snapshotVersion))
                ),
                on: transaction
            )
            return page
        }
    }
}


extension Controller {
    func getParticipantTasks(_ input: Operations.GetParticipantTasks.Input) async throws -> Operations.GetParticipantTasks.Output {
        let page = try await consentService.taskPage(
            enrollmentID: input.path.enrollmentId.requireId(),
            cursor: input.query.cursor.map { try $0.requireId() },
            limit: input.query.limit ?? 50
        )
        return .ok(.init(headers: .init(cacheControl: .noStore), body: .json(page)))
    }
}
