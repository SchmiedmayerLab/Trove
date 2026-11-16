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


extension ConsentService {
    /// Completion acknowledges local acquisition exhaustion, not upload or permission for another query.
    func completeNativeReconciliation(enrollmentID: UUID, sourceID: UUID, id: UUID, proof: SourceInstallationProof) async throws {
        let context = try AuthContext.checkIsParticipant()
        let owned = try await authorizationService.checkParticipantHasEnrollmentAccess(id: enrollmentID)
        let study = try await verifiedStudyContext(enrollment: owned)
        try await repository.database.transaction { transaction in
            let participantID = try await SourceBindingService.lockParticipant(context, on: transaction)
            guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            _ = try await Self.reconciliationSource(id: sourceID, participantID: participantID, proof: proof, on: transaction)
            let enrollment = try await self.repository.lockEnrollment(id: enrollmentID, on: transaction)
            guard enrollment.$participant.id == participantID else { throw ServerError.notFound("Enrollment not found") }
            try await NativeCollectionReconciliationStore(database: sql, participantID: participantID)
                .complete(id: id, sourceID: sourceID, enrollmentID: enrollmentID, now: .now)
            try await AuditRepository.recordMutation(.init(
                context: study.audit,
                action: .collectionReconciliationCompleted,
                scope: .study(studyID: study.scope.studyID, groupID: study.scope.groupID),
                target: .init(id: id)
            ), on: transaction)
        }
    }
}
