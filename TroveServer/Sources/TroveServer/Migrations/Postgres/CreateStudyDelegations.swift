//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import SQLKit


struct CreateStudyDelegations: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("study_delegations")
            .id()
            .field("study_id", .uuid, .required, .references("studies", "id", onDelete: .cascade))
            .field("grantor_issuer", .string, .required)
            .field("grantor_subject", .string, .required)
            .field("client_id", .string, .required)
            .field("preset", .string, .required)
            .field("created_at", .datetime, .required)
            .field("expires_at", .datetime, .required)
            .field("revoked_at", .datetime)
            .constraint(.custom(SQLConstraint(algorithm: SQLTableConstraintAlgorithm.check(SQLRaw("""
                preset IN ('inspectStudy', 'editStudyDraft') AND expires_at > created_at
                AND (revoked_at IS NULL OR revoked_at >= created_at)
                AND length(client_id) BETWEEN 1 AND 255
                AND length(grantor_subject) BETWEEN 1 AND 255
                AND length(grantor_issuer) BETWEEN 1 AND 2048
                """)), name: SQLIdentifier("study_delegations_valid"))))
            .create()
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        try await sql.raw("CREATE INDEX study_delegations_study ON study_delegations (study_id, created_at, id)").run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("study_delegations").delete()
    }
}
