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


/// Shared by initial admission and late attribution inside the source-owner transaction.
struct ClinicalGrantStore: Sendable {
    struct Output: Sendable {
        let fullURL: String
        let profile: String
        let effectiveAt: Date
    }

    struct Authority: Sendable {
        let studyID: UUID
        let groupID: UUID
        let enrollmentID: UUID
        let consentID: UUID
        let publicationID: UUID
        let revision: Int
        let outputs: Set<String>
        let custody: Set<String>
    }

    let database: any Database
    let source: SourceBinding
    let context: AuthContext
    let acceptedAt: Date

    func authorities(outputs: [Output], intent: ClinicalEventIntent, requireCustodyCoverage: Bool) async throws -> [Authority] {
        guard database.inTransaction else { throw ServerError.unexpectedError }
        var records: [(ClinicalEventTarget, EnrollmentConsent)] = []
        for target in intent.targets {
            // Do not read signatures or artifact metadata to resolve a collection target.
            let consent = try await EnrollmentConsent.query(on: database)
                .filter(\.$id == target.consentID)
                .field(\.$id)
                .field(\.$enrollment.$id)
                .first()
            guard let consent,
                  let enrollment = try await Enrollment.find(consent.$enrollment.id, on: database),
                  enrollment.$participant.id == source.participantID else {
                throw ServerError.notFound("Consent target not found")
            }
            records.append((target, consent))
        }
        // Participant was locked first; acquire enrollment locks in one order for both commands.
        let repository = ConsentRepository(database: database)
        var enrollments: [UUID: Enrollment] = [:]
        var timelines: [UUID: [ConsentCollectionTimeline.Window]] = [:]
        for id in Set(records.map { $0.1.$enrollment.id }).sorted(by: { $0.uuidString < $1.uuidString }) {
            let enrollment = try await repository.lockEnrollment(id: id, on: database)
            enrollments[id] = enrollment
            timelines[id] = try await ConsentCollectionTimeline.load(enrollment: enrollment, on: database, asOf: acceptedAt)
        }
        var result: [Authority] = []
        for (target, consent) in records {
            guard let enrollment = enrollments[consent.$enrollment.id],
                  let interval = timelines[consent.$enrollment.id]?.first(where: { $0.acceptance.consentID == target.consentID }) else {
                throw ServerError.forbidden("Exact consent is missing from its enrollment history")
            }
            result.append(try await authority(target: target, interval: interval, enrollment: enrollment, outputs: outputs))
        }
        if requireCustodyCoverage {
            let covered = result.reduce(into: Set<String>()) { $0.formUnion($1.custody) }
            guard covered == Set(outputs.map(\.fullURL)) else {
                throw ServerError.forbidden("Every retained clinical output requires a consented collection purpose")
            }
        }
        return result
    }

    func insert(_ authority: Authority, nodeID: UUID) async throws -> UUID {
        guard let sql = database as? any SQLDatabase, database.inTransaction else { throw ServerError.unexpectedError }
        // A different command may request an already granted exact output. Never duplicate its evidence.
        if let row = try await sql.raw("""
            SELECT id FROM study_data_grants WHERE node_id = \(bind: nodeID) AND consent_id = \(bind: authority.consentID)
            """)
            .first() {
            return try row.decode(column: "id", as: UUID.self)
        }
        let id = UUID()
        try await sql.raw("""
            INSERT INTO study_data_grants (id, node_id, source_id, participant_id, study_id, enrollment_id,
                consent_id, publication_id, revision, accepted_at)
            VALUES (\(bind: id), \(bind: nodeID), \(bind: source.id), \(bind: source.participantID),
                \(bind: authority.studyID), \(bind: authority.enrollmentID), \(bind: authority.consentID),
                \(bind: authority.publicationID), \(bind: authority.revision), \(bind: acceptedAt))
            """)
            .run()
        try await AuditRepository.recordMutation(.init(
            context: context.auditContext,
            action: .studyDataGranted,
            scope: .study(studyID: authority.studyID, groupID: authority.groupID),
            target: .init(id: id, version: String(authority.revision))
        ), on: database)
        return id
    }
}


extension ClinicalGrantStore {
    private func authority(
        target: ClinicalEventTarget, interval: ConsentCollectionTimeline.Window, enrollment: Enrollment, outputs: [Output]
    ) async throws -> Authority {
        guard enrollment.$participant.id == source.participantID else { throw ServerError.notFound("Consent target not found") }
        guard enrollment.withdrawnAt == nil else { throw ServerError.forbidden("Enrollment is withdrawn") }
        let consent = interval.acceptance
        guard let publication = try await PublishedStudy.find(consent.publicationID, on: database),
              publication.$study.id == enrollment.$study.id, publication.revision == consent.revision,
              let study = try await Study.find(enrollment.$study.id, on: database) else {
            throw ServerError.forbidden("Exact reviewed publication is required for study data")
        }
        let permitted = Set(outputs.filter { output in
            output.effectiveAt <= acceptedAt && (interval.end.map { output.effectiveAt < $0 } ?? true)
                && publication.collectionPolicy.permits(
                    studyID: enrollment.$study.id,
                    revision: consent.revision,
                    profile: output.profile,
                    sourceKind: source.kind,
                    effectiveAt: output.effectiveAt,
                    consentAcceptedAt: consent.acceptedAt
                )
        }
        .map(\.fullURL))
        let selected = Set(target.outputFullURLs)
        guard selected.isSubset(of: permitted) else {
            throw ServerError.forbidden("Requested output is absent or outside the exact consent's collection interval")
        }
        return .init(
            studyID: enrollment.$study.id,
            groupID: study.$group.id,
            enrollmentID: try enrollment.requireID(),
            consentID: target.consentID,
            publicationID: try publication.requireID(),
            revision: consent.revision,
            outputs: selected,
            custody: permitted
        )
    }
}
