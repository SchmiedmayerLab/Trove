//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import FluentPostgresDriver
import Foundation
import Grove
import SQLKit


final class StudyRepository: Module, Sendable {
    let database: any Database

    init(database: any Database) {
        self.database = database
    }

    func create(_ study: Study) async throws -> Study {
        try await study.save(on: database)
        return study
    }

    func find(id: UUID) async throws -> Study? {
        try await Study.find(id, on: database)
    }

    func findWithComponents(id: UUID) async throws -> Study? {
        try await Study.query(on: database)
            .filter(\.$id == id)
            .with(\.$components)
            .first()
    }

    func findWithComponentsAndSchedules(id: UUID) async throws -> Study? {
        try await database.transaction { transaction in
            if transaction is any PostgresDatabase, let sql = transaction as? any SQLDatabase {
                // A publication must not combine component queries from different draft states.
                try await sql.raw("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY").run()
            }
            return try await self.loadWithComponentsAndSchedules(id: id, on: transaction)
        }
    }

    private func loadWithComponentsAndSchedules(id: UUID, on database: any Database) async throws -> Study? {
        guard let study = try await Study.query(on: database)
            .filter(\.$id == id)
            .with(\.$components)
            .first() else {
            return nil
        }

        for component in study.components {
            try await component.$schedules.load(on: database)
        }

        return study
    }

    func listIds() async throws -> [UUID] {
        try await Study.query(on: database).all(\.$id)
    }

    func listAll(groupId: UUID) async throws -> [Study] {
        try await Study.query(on: database)
            .filter(\.$group.$id == groupId)
            .all()
    }

    func update(_ study: Study) async throws -> Study {
        try await study.save(on: database)
        return study
    }

    /// The row lock serializes deletion with inserts that reference the study through foreign keys.
    /// The caller records the deletion audit event before committing this transaction.
    func deleteUnusedDraft(id: UUID, expectedGroupID: UUID, on transaction: any Database) async throws -> Study? {
        guard transaction.inTransaction else { throw AuditError.transactionRequired }
        guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        if transaction is any PostgresDatabase {
            _ = try await sql.raw("SELECT id FROM studies WHERE id = \(bind: id) FOR UPDATE").first()
        } else {
            // SQLite has no row-level FOR UPDATE; acquire its writer lock before reading references.
            try await sql.raw("UPDATE studies SET id = id WHERE id = \(bind: id)").run()
        }
        guard let study = try await Study.find(id, on: transaction) else {
            return nil
        }
        guard study.$group.id == expectedGroupID else { throw ServerError.forbidden }
        let publication = try await PublishedStudy.query(on: transaction).filter(\.$study.$id == id).field(\.$id).first()
        let enrollment = try await Enrollment.query(on: transaction).filter(\.$study.$id == id).field(\.$id).first()
        guard publication == nil, enrollment == nil else {
            throw ServerError.conflict("Published or enrolled studies cannot be deleted")
        }
        try await study.delete(on: transaction)
        return study
    }
}
