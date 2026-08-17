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


final class PublishedStudyRepository: Module, Sendable {
    let database: any Database

    init(database: any Database) {
        self.database = database
    }

    func listByStudyId(_ studyId: UUID) async throws -> [PublishedStudy] {
        try await PublishedStudy.query(on: database)
            .filter(\.$study.$id == studyId)
            .all()
    }

    func maxRevision(forStudyId studyId: UUID) async throws -> Int? {
        try await PublishedStudy.query(on: database)
            .filter(\.$study.$id == studyId)
            .max(\.$revision)
    }

    func create(_ publishedStudy: PublishedStudy) async throws -> PublishedStudy {
        try await publishedStudy.save(on: database)
        return publishedStudy
    }

    /// Returns the latest revision of each study, but only if that revision is public.
    /// Studies whose latest revision is unlisted are intentionally excluded — earlier
    /// public revisions are not surfaced.
    func listLatestPublicStudies() async throws -> [PublishedStudy] {
        guard let sql = database as? any SQLDatabase else {
            throw ServerError.internalServerError("Database does not support SQL")
        }

        let rows = try await sql.raw("""
            SELECT published_study.id
            FROM \(unsafeRaw: PublishedStudy.schema) published_study
            INNER JOIN (
                SELECT study_id, MAX(revision) AS max_revision
                FROM \(unsafeRaw: PublishedStudy.schema)
                GROUP BY study_id
            ) latest ON published_study.study_id = latest.study_id
                AND published_study.revision = latest.max_revision
            WHERE published_study.visibility = 'public'
            """)
            .all()

        let ids = try rows.map { try $0.decode(column: "id", as: UUID.self) }
        guard !ids.isEmpty else {
            return []
        }

        return try await PublishedStudy.query(on: database)
            .filter(\.$id ~~ ids)
            .all()
    }

    /// Lookup: returns the latest published revision for a specific study.
    func findLatestPublished(forStudyId studyId: UUID) async throws -> PublishedStudy? {
        try await PublishedStudy.query(on: database)
            .filter(\.$study.$id == studyId)
            .sort(\.$revision, .descending)
            .first()
    }
}
