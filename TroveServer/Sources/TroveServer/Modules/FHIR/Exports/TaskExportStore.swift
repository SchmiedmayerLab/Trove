// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Fluent
import Foundation
import SQLKit


extension TaskExportMember {
    /// Records read once per enrollment and publication while members are authorized in one call.
    struct AuthorizationCache {
        fileprivate var enrollments: [UUID: Enrollment] = [:]
        fileprivate var publications: [UUID: PublishedStudy] = [:]
        fileprivate var histories: [UUID: [ConsentCollectionTimeline.Window]] = [:]
    }

    static let maximumMembers = 1000

    /// Reads every occurrence of the study's eligible enrollments, or exactly the given occurrences.
    /// A caller that relies on the members' state holds the participant and enrollment locks of every returned member.
    static func select(
        study: UUID, ids: [String]?, on database: any Database // swiftlint:disable:this discouraged_optional_collection
    ) async throws -> [Self] {
        guard database.inTransaction, let sql = database as? any SQLDatabase else { throw AuditError.transactionRequired }
        if ids?.isEmpty == true {
            return []
        }
        let subset: SQLQueryString = ids.map { "AND o.id IN (\(binds: $0))" } ?? ""
        let rows = try await rows(study: study, subset: subset, limit: maximumMembers + 1, on: sql)
        guard rows.count <= maximumMembers else { throw ServerError.conflict("Export exceeds the bounded snapshot capacity") }
        var enrollments: [UUID: Enrollment] = [:]
        var members: [Self] = []
        for row in rows {
            let id = try row.decode(column: "enrollment_id", as: UUID.self)
            if enrollments[id] == nil {
                guard let enrollment = try await Enrollment.find(id, on: database), enrollment.withdrawnAt == nil else {
                    throw ServerError.forbidden
                }
                enrollments[id] = enrollment
            }
            guard let enrollment = enrollments[id] else { throw ServerError.unexpectedError }
            members.append(try Self(row: row, study: study, enrollment: enrollment))
        }
        if let ids, Set(members.map(\.occurrence)) != Set(ids) { throw ServerError.forbidden }
        return members
    }

    /// Rechecks frozen members against the current task store. The assignment facts are immutable; a frozen
    /// completion must still be the same accepted result. A later completion or stop of a frozen open
    /// occurrence leaves the snapshot unchanged.
    static func check(_ members: [Self], study: Study, on database: any Database) async throws {
        let current = try await select(study: study.requireID(), ids: members.map(\.occurrence), on: database)
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.occurrence, $0) })
        var cache = AuthorizationCache()
        for member in members {
            guard let now = byID[member.occurrence], now.assignment == member.assignment, now.instrument == member.instrument,
                  now.assignedAt == member.assignedAt, now.window == member.window,
                  member.status != .completed && member.status != .failed || now == member,
                  member.status != .cancelled || now.status == .cancelled else { throw ServerError.forbidden }
            try await member.authorize(group: study.$group.id, cache: &cache, on: database)
        }
    }

    func authorize(group: UUID, cache: inout AuthorizationCache, on database: any Database) async throws {
        guard database.inTransaction else { throw ServerError.forbidden }
        if cache.enrollments[enrollment] == nil { cache.enrollments[enrollment] = try await Enrollment.find(enrollment, on: database) }
        if cache.publications[instrument.publicationID] == nil {
            cache.publications[instrument.publicationID] = try await PublishedStudy.find(instrument.publicationID, on: database)
        }
        guard let enrollmentRow = cache.enrollments[enrollment],
              enrollmentRow.withdrawnAt == nil, enrollmentRow.$participant.id == participant,
              enrollmentRow.$study.id == instrument.studyID,
              let publication = cache.publications[instrument.publicationID],
              publication.$study.id == instrument.studyID, publication.revision == instrument.revision,
              publication.artifactID == instrument.artifactID else { throw ServerError.forbidden }
        guard let completion else {
            return
        }
        if cache.histories[enrollment] == nil {
            cache.histories[enrollment] = try await ConsentCollectionTimeline.load(enrollment: enrollmentRow, on: database, asOf: Date())
        }
        let history = cache.histories[enrollment] ?? []
        guard history.contains(where: {
            $0.acceptance.consentID == completion.consent && $0.acceptance.publicationID == instrument.publicationID &&
                $0.acceptance.revision == instrument.revision
        }) else { throw ServerError.forbidden }
        _ = try await responseReference(completion, group: group, on: database)
    }

    private func responseReference(_ completion: Completion, group: UUID, on database: any Database) async throws -> ArtifactReference {
        guard let row = try await StoredArtifact.find(completion.responseArtifact, on: database), row.state == .retained,
              row.ownerID == enrollment, row.purpose == .taskResponse, row.digest == completion.responseDigest,
              (1...FHIRValidationClient.maximumBytes).contains(row.byteCount),
              try row.reference().scope == .study(.init(studyID: instrument.studyID, groupID: group)) else { throw ServerError.forbidden }
        return try row.reference()
    }

    /// The accepted response bytes, read from retained storage and checked against the receipt digest.
    func acceptedResponse(group: UUID, objects: TaskExportObjects, using artifacts: ArtifactStore) async throws -> Data? {
        guard let completion else {
            return nil
        }
        let reference = try await responseReference(completion, group: group, on: artifacts.database)
        return try await objects.bytes(
            id: completion.responseArtifact,
            ownerID: enrollment,
            purpose: .taskResponse,
            expected: (reference.key, completion.responseDigest),
            using: artifacts
        )
    }
}
