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


/// All access uses the caller's study-locked transaction; no independent authority store.
enum DelegationRepository {
    static func find(id: UUID, studyID: UUID, on transaction: any Database) async throws -> DelegationGrant? {
        let sql = try requireTransaction(transaction)
        return try await sql.raw("SELECT * FROM study_delegations WHERE id = \(bind: id) AND study_id = \(bind: studyID)")
            .first()
            .map { try DelegationGrant(row: $0) }
    }

    static func list(
        studyID: UUID, owner: AuditActor?, before: UUID?, limit: Int, on transaction: any Database
    ) async throws -> DelegationPage {
        guard (1...100).contains(limit) else { throw ServerError.badRequest("Delegation page limit must be between 1 and 100") }
        let sql = try requireTransaction(transaction)
        var scope: SQLQueryString = "study_id = \(bind: studyID)"
        if let owner {
            scope = "\(scope) AND grantor_issuer = \(bind: owner.issuer) AND grantor_subject = \(bind: owner.subject)"
        }
        var boundary: SQLQueryString = ""
        if let before {
            let anchor = try await sql.raw("SELECT id FROM study_delegations WHERE \(scope) AND id = \(bind: before)").first()
            guard anchor != nil else {
                throw ServerError.badRequest("Invalid delegation page cursor")
            }
            boundary = """
                AND (created_at, id) < (SELECT created_at, id FROM study_delegations WHERE \(scope) AND id = \(bind: before))
                """
        }
        let rows = try await sql.raw("""
            SELECT * FROM study_delegations WHERE \(scope) \(boundary) ORDER BY created_at DESC, id DESC LIMIT \(bind: limit + 1)
            """)
            .all()
        let grants = try rows.prefix(limit).map { try DelegationGrant(row: $0) }
        return .init(grants: grants, nextBefore: rows.count > limit ? grants.last?.id : nil)
    }

    static func create(_ grant: DelegationGrant, on transaction: any Database) async throws {
        let sql = try requireTransaction(transaction)
        try await sql.raw("""
            INSERT INTO study_delegations
                (id, study_id, grantor_issuer, grantor_subject, client_id, preset, created_at, expires_at)
            VALUES (\(bind: grant.id), \(bind: grant.studyID), \(bind: grant.grantor.issuer), \(bind: grant.grantor.subject),
                \(bind: grant.clientID), \(bind: grant.preset.rawValue), \(bind: grant.createdAt), \(bind: grant.expiresAt))
            """)
            .run()
    }

    static func revoke(_ grant: DelegationGrant, at date: Date, on transaction: any Database) async throws -> DelegationGrant {
        let sql = try requireTransaction(transaction)
        try await sql.raw("""
            UPDATE study_delegations SET revoked_at = \(bind: date)
            WHERE id = \(bind: grant.id) AND study_id = \(bind: grant.studyID) AND revoked_at IS NULL
            """)
            .run()
        guard let result = try await find(id: grant.id, studyID: grant.studyID, on: transaction) else {
            throw ServerError.forbidden
        }
        return result
    }

    private static func requireTransaction(_ database: any Database) throws -> any SQLDatabase {
        guard database.inTransaction else { throw AuditError.transactionRequired }
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        return sql
    }
}
