//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation


/// One adoption timeline for collection planning and exact-output admission.
enum ConsentCollectionTimeline {
    struct Acceptance: Sendable {
        let consentID: UUID
        let publicationID: UUID
        let revision: Int
        let stateVersion: Int64
        let acceptedAt: Date
    }

    struct Window: Sendable {
        let acceptance: Acceptance
        let end: Date?
    }

    static let maximumAcceptances = 1024
    static let inconsistent = ServerError.forbidden("Consent history is inconsistent")

    /// Caller holds the enrollment lock until it finishes using this snapshot.
    static func load(enrollment: Enrollment, on database: any Database, asOf: Date) async throws -> [Window] {
        guard database.inTransaction else { throw ServerError.unexpectedError }
        let records = try await EnrollmentConsent.query(on: database)
            .filter(\.$enrollment.$id == enrollment.requireID())
            .field(\.$id)
            .field(\.$revision)
            .field(\.$acceptedEnrollmentVersion)
            .field(\.$createdAt)
            .field(\.$presentationProof)
            .sort(\.$acceptedEnrollmentVersion, .ascending)
            .range(..<(maximumAcceptances + 1))
            .all()
        let acceptances = try records.map { record in
            guard let acceptedAt = record.createdAt else { throw inconsistent }
            return Acceptance(
                consentID: try record.requireID(),
                publicationID: record.presentationProof.presentationID,
                revision: record.revision,
                stateVersion: record.acceptedEnrollmentVersion,
                acceptedAt: acceptedAt
            )
        }
        return try windows(acceptances, currentRevision: enrollment.currentRevision, stateVersion: enrollment.stateVersion, asOf: asOf)
    }

    static func windows(_ history: [Acceptance], currentRevision: Int, stateVersion: Int64, asOf: Date) throws -> [Window] {
        guard history.count <= maximumAcceptances, asOf.timeIntervalSinceReferenceDate.isFinite,
              currentRevision > 0, stateVersion > 0 else { throw inconsistent }
        guard let last = history.last else {
            return []
        }
        guard last.revision == currentRevision, last.stateVersion <= stateVersion else { throw inconsistent }
        var previousTime: Date?
        var previousVersion: Int64 = 0
        var previousRevision = 0
        var ids: Set<UUID> = []
        for record in history {
            guard record.acceptedAt.timeIntervalSinceReferenceDate.isFinite, record.acceptedAt <= asOf,
                  previousTime.map({ record.acceptedAt >= $0 }) ?? true,
                  record.stateVersion > previousVersion, record.revision > previousRevision,
                  ids.insert(record.consentID).inserted else { throw inconsistent }
            previousTime = record.acceptedAt
            previousVersion = record.stateVersion
            previousRevision = record.revision
        }
        return history.indices.map { index in
            Window(acceptance: history[index], end: index + 1 < history.count ? history[index + 1].acceptedAt : nil)
        }
    }
}
