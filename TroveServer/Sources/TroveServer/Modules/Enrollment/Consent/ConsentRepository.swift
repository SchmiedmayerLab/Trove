//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Grove
import SQLKit


final class ConsentRepository: Module, Sendable {
    let database: any Database

    init(database: any Database) {
        self.database = database
    }

    func listConsentRecords(enrollmentId: UUID) async throws -> [EnrollmentConsent] {
        try await EnrollmentConsent.query(on: database)
            .filter(\.$enrollment.$id == enrollmentId)
            .all()
    }

    func findConsentRecord(id: UUID, enrollmentId: UUID) async throws -> EnrollmentConsent? {
        // swiftlint:disable:next first_where - Fluent query builder, not a Sequence
        try await EnrollmentConsent.query(on: database)
            .filter(\.$id == id)
            .filter(\.$enrollment.$id == enrollmentId)
            .first()
    }

    func findConsentRecord(enrollmentId: UUID, revision: Int, on transaction: (any Database)? = nil) async throws -> EnrollmentConsent? {
        // swiftlint:disable:next first_where - Fluent query builder, not a Sequence
        try await EnrollmentConsent.query(on: transaction ?? database)
            .filter(\.$enrollment.$id == enrollmentId)
            .filter(\.$revision == revision)
            .first()
    }

    func findCommand(enrollmentID: UUID, commandID: UUID, on transaction: (any Database)? = nil) async throws -> EnrollmentConsent? {
        // swiftlint:disable:next first_where - Fluent query builder, not a Sequence
        try await EnrollmentConsent.query(on: transaction ?? database)
            .filter(\.$enrollment.$id == enrollmentID)
            .filter(\.$commandID == commandID)
            .first()
    }

    /// Lock before checking command receipts: a completed command remains replayable after withdrawal.
    func lockEnrollment(id: UUID, on transaction: any Database) async throws -> Enrollment {
        guard transaction.inTransaction, let sql = transaction as? any SQLDatabase else {
            throw ServerError.internalServerError("Enrollment changes require a SQL transaction")
        }
        let rows = try await sql.raw("""
            UPDATE enrollments SET state_version = state_version WHERE id = \(bind: id) RETURNING id
            """)
            .all()
        guard rows.count == 1, let enrollment = try await Enrollment.find(id, on: transaction) else {
            throw ServerError.notFound("Enrollment not found")
        }
        return enrollment
    }

    func advanceEnrollmentVersion(id: UUID, expectedVersion: Int64, on transaction: any Database) async throws -> Int64 {
        guard transaction.inTransaction, let sql = transaction as? any SQLDatabase else {
            throw ServerError.internalServerError("Enrollment changes require a SQL transaction")
        }
        guard expectedVersion > 0, expectedVersion < Int64.max else {
            throw ServerError.conflict("Enrollment state version cannot advance")
        }
        let row = try await sql.raw("""
            UPDATE enrollments SET state_version = state_version + 1
            WHERE id = \(bind: id) AND state_version = \(bind: expectedVersion)
            RETURNING state_version
            """)
            .first()
        guard let row else {
            throw ServerError.preconditionFailed("Enrollment state changed before the operation could complete")
        }
        return try row.decode(column: "state_version", as: Int64.self)
    }

    /// Serialize eligibility reads with ordinary profile UPDATEs until acceptance commits.
    /// Consent locks participant before enrollment, matching participant deletion's cascade order.
    func lockParticipant(id: UUID, on transaction: any Database) async throws -> Participant {
        guard transaction.inTransaction, let sql = transaction as? any SQLDatabase else {
            throw ServerError.internalServerError("Consent eligibility requires a SQL transaction")
        }
        let rows = try await sql.raw("""
            UPDATE participants SET id = id WHERE id = \(bind: id) RETURNING id
            """)
            .all()
        guard rows.count == 1, let participant = try await Participant.find(id, on: transaction) else {
            throw ServerError.notFound("Participant not found")
        }
        return participant
    }

    /// Fresh consent is required for every forward revision, even when its content is unchanged.
    func adoptRevision(id: UUID, expectedVersion: Int64, revision: Int, on transaction: any Database) async throws -> Int64 {
        guard transaction.inTransaction, let sql = transaction as? any SQLDatabase else {
            throw ServerError.internalServerError("Consent adoption requires a SQL transaction")
        }
        guard expectedVersion > 0, expectedVersion < Int64.max, revision > 0 else {
            throw ServerError.conflict("Enrollment state cannot advance")
        }
        let row = try await sql.raw("""
            UPDATE enrollments SET current_revision = \(bind: revision), state_version = state_version + 1
            WHERE id = \(bind: id) AND state_version = \(bind: expectedVersion)
                AND current_revision <= \(bind: revision) AND withdrawn_at IS NULL
            RETURNING state_version
            """)
            .first()
        guard let row else {
            throw ServerError.preconditionFailed("Enrollment state changed before consent could be accepted")
        }
        return try row.decode(column: "state_version", as: Int64.self)
    }
}
