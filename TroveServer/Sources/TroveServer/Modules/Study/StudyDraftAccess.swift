//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation


extension StudyService {
    /// The committed disclosure intent and captured result share the revocation fence.
    /// Callers must load their complete result on the supplied transaction, not another pool lease.
    func readDraft<Value: Sendable>(
        id: UUID,
        read: @escaping @Sendable (Study, any Database) async throws -> Value
    ) async throws -> Value {
        let access = try await authorizationService.prepareDraftAccess(operation: .inspect)
        return try await repository.database.transaction { transaction in
            let study = try await self.repository.lockStudy(id: id, on: transaction)
            let context = try await self.authorizationService.authorizeDraft(access, study: study, on: transaction)
            let value = try await read(study, transaction)
            try await AuditRepository.recordDisclosureIntent(AuditEvent(
                context: context,
                action: .studyDraftDisclosure,
                scope: .study(studyID: id, groupID: study.$group.id),
                target: .init(id: id, version: study.draftRevision.uuidString)
            ), on: transaction)
            return value
        }
    }

    /// All interpretation-relevant writes advance the same revision, including component and
    /// schedule changes. Authorization, the write and its audit event commit or roll back together.
    func editDraft<Value: Sendable>(
        id: UUID,
        expectedRevision: UUID,
        edit: @escaping @Sendable (Study, any Database) async throws -> Value
    ) async throws -> Value {
        let access = try await authorizationService.prepareDraftAccess(operation: .edit)
        return try await repository.database.transaction { transaction in
            let study = try await self.repository.lockStudy(id: id, on: transaction)
            let context = try await self.authorizationService.authorizeDraft(access, study: study, on: transaction)
            try study.requireDraftRevision(expectedRevision)
            let value = try await edit(study, transaction)
            try await self.repository.advanceDraftRevision(study, on: transaction)
            try await AuditRepository.recordMutation(AuditEvent(
                context: context,
                action: .studyDraftEdited,
                scope: .study(studyID: id, groupID: study.$group.id),
                target: .init(id: id, version: study.draftRevision.uuidString)
            ), on: transaction)
            return value
        }
    }
}
