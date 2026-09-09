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


struct ArtifactCleanupReport: Sendable {
    var deleted = 0
    var failed = 0
}


extension ArtifactStore {
    /// Operator-only bounded sweep. A tombstone remains eligible for later sweeps because
    /// an interrupted remote PUT can complete after a DELETE has returned.
    func cleanup(
        limit: Int = 100, now: Date = Date(), auditContext: AuditEvent.Context = .artifactCleanup()
    ) async throws -> ArtifactCleanupReport {
        guard (1...100).contains(limit) else { throw Failure.invalidCleanupBatch }
        guard !database.inTransaction else { throw Failure.operationInsideTransaction }
        let references = try await claimCleanup(limit: limit, now: now, auditContext: auditContext)
        var report = ArtifactCleanupReport()
        for reference in references {
            try Task.checkCancellation()
            do {
                try await storage.delete(key: reference.key)
                try await StoredArtifact.query(on: database)
                    .filter(\.$id == reference.id)
                    .filter(\.$state == .discarding)
                    .set(\.$lastDeletedAt, to: Date())
                    .update()
                report.deleted += 1
            } catch {
                try Task.checkCancellation()
                // The durable claim stays retryable; never discard its recovery locator.
                report.failed += 1
            }
        }
        return report
    }

    private func claimCleanup(limit: Int, now: Date, auditContext: AuditEvent.Context) async throws -> [ArtifactReference] {
        try await database.transaction { transaction in
            let records = try await StoredArtifact.query(on: transaction)
                .filter(\.$cleanupAfter <= now)
                .filter(\.$state != .retained)
                // Exclude protected rows before limiting the batch. A damaged registry state
                // must not let referenced artifacts repeatedly starve later cleanup candidates.
                .filter(.custom(SQLRaw("""
                    NOT EXISTS (SELECT 1 FROM enrollment_consents WHERE artifact_id = stored_artifacts.id)
                    AND NOT EXISTS (SELECT 1 FROM published_studies WHERE artifact_id = stored_artifacts.id)
                    """)))
                .sort(\.$cleanupAfter)
                .sort(\.$id)
                .limit(limit)
                .all()
            var claimed: [ArtifactReference] = []
            for record in records where try await self.fenceCleanup(record, now: now, on: transaction) {
                let event = AuditEvent(
                    context: auditContext,
                    action: .artifactDiscardScheduled,
                    scope: .study(studyID: record.studyID, groupID: record.groupID),
                    target: .init(id: try record.requireID())
                )
                try await AuditRepository.recordMutation(event, on: transaction)
                claimed.append(try record.reference())
            }
            return claimed
        }
    }

    private func fenceCleanup(_ record: StoredArtifact, now: Date, on transaction: any Database) async throws -> Bool {
        guard let sql = transaction as? any SQLDatabase else { throw Failure.unsupportedDatabase }
        let result = try await sql.raw("""
            UPDATE stored_artifacts SET state = 'discarding', cleanup_after = \(bind: now.addingTimeInterval(3600))
            WHERE id = \(bind: record.requireID()) AND state <> 'retained' AND cleanup_after <= \(bind: now)
              AND NOT EXISTS (SELECT 1 FROM enrollment_consents WHERE artifact_id = stored_artifacts.id)
              AND NOT EXISTS (SELECT 1 FROM published_studies WHERE artifact_id = stored_artifacts.id)
            RETURNING id
            """)
            .first()
        return result != nil
    }
}
