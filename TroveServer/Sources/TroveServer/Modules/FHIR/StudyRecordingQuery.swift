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


extension StudyDataQuery {
    /// Resolves a study-scoped grant using the same eligibility rules as page selection.
    /// The resulting candidate must still be fenced before storage access or disclosure.
    func recording(grantID: UUID, studyID: UUID, versions: Versions) async throws -> Page {
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        let eligible = Self.eligibleOutputs(studyID: studyID, versions: versions, on: sql)
        let rows = try await sql.raw("""
            WITH eligible AS (\(eligible))
            SELECT e.* FROM eligible e
            JOIN study_data_grants g ON g.node_id = e.node_id AND g.enrollment_id = e.enrollment_id
            JOIN clinical_recording_attachments a ON a.node_id = e.node_id
            WHERE g.id = \(bind: grantID) AND g.study_id = \(bind: studyID)
            """)
            .all()
        guard rows.count == 1, let row = rows.first else { throw ServerError.notFound("Study recording not found") }
        return try .init(outputs: [Output(row: row)], nextBefore: nil)
    }
}


extension StudyDataQuery {
    /// Proves again, before a study view or any recording byte is prepared, that the grant's exact consent
    /// window selects every row of a query-created batch. This covers the recording and the summary derived
    /// from it. A grant without this proof discloses nothing; page export and recording download share this rule.
    func requireEveryRowSelected(
        _ event: ValidatedExchangeEvent, output: Output, grant: StudyDataFence.Grant, studyID: UUID, otherwise unavailable: ServerError
    ) async throws {
        guard database.inTransaction else { throw AuditError.transactionRequired }
        guard let facts = event.collectionOutputs.first(where: { $0.fullURL == output.fullURL }), !facts.lacksRowEvidence else {
            throw unavailable
        }
        guard facts.rowExtent != nil else {
            return
        }
        guard let profile = facts.collectionProfile,
              let enrollment = try await Enrollment.find(grant.enrollmentID, on: database), enrollment.$study.id == studyID,
              let publication = try await PublishedStudy.find(grant.publicationID, on: database),
              publication.$study.id == studyID, publication.revision == grant.revision,
              let interval = try await ConsentCollectionTimeline.load(enrollment: enrollment, on: database, asOf: Date())
                  .first(where: { $0.acceptance.consentID == grant.consentID }),
              let sql = database as? any SQLDatabase,
              let row = try await sql.raw("SELECT * FROM source_bindings WHERE id = \(bind: output.sourceID)").first() else {
            throw unavailable
        }
        let source = try SourceBinding(row: row)
        guard publication.collectionPolicy.permits(
            studyID: studyID,
            revision: grant.revision,
            profile: profile,
            sourceKind: source.kind,
            effectiveAt: facts.effectiveAt,
            consentAcceptedAt: interval.acceptance.acceptedAt,
            effectiveEnd: facts.effectiveEnd,
            preciseBounds: facts.measurementBounds,
            scope: interval.acceptance.collectionScope,
            adoptionEnd: interval.end,
            providerRegistrationID: source.providerRegistrationID,
            sourceTypeIdentifier: facts.sourceTypeIdentifier,
            timeBasis: facts.timeBasis,
            rowExtent: facts.rowExtent
        ) else { throw unavailable }
    }
}
