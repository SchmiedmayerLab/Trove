//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import TroveAPIServer


extension ConsentService {
    func collectionPlan(enrollmentID: UUID) async throws -> Components.Schemas.ParticipantCollectionPlan {
        let owned = try await authorizationService.checkParticipantHasEnrollmentAccess(id: enrollmentID)
        let participantID = owned.$participant.id
        let context = try await verifiedStudyContext(enrollment: owned)
        let event = AuditEvent(
            context: context.audit,
            action: .collectionPlanDisclosure,
            scope: .study(studyID: context.scope.studyID, groupID: context.scope.groupID),
            target: .init(id: enrollmentID)
        )
        return try await AuditRepository.disclose(event, on: repository.database) { _ in
            try await self.repository.database.transaction { transaction in
                let enrollment = try await self.repository.lockEnrollment(id: enrollmentID, on: transaction)
                guard enrollment.$participant.id == participantID else { throw ServerError.notFound("Enrollment not found") }
                let asOf = Date()
                var windows: [Components.Schemas.ConsentCollectionWindow] = []
                if enrollment.withdrawnAt == nil {
                    let timeline = try await ConsentCollectionTimeline.load(enrollment: enrollment, on: transaction, asOf: asOf)
                    windows = try await Self.collectionWindows(timeline, studyID: enrollment.$study.id, on: transaction)
                }
                let title = try await Self.collectionTitle(enrollment: enrollment, on: transaction)
                return .init(
                    enrollmentId: enrollmentID.uuidString.lowercased(),
                    studyId: enrollment.$study.id.uuidString.lowercased(),
                    title: title,
                    endsAt: enrollment.endsAt,
                    stateVersion: enrollment.stateVersion,
                    asOf: asOf,
                    windows: windows
                )
            }
        }
    }
}


extension ConsentService {
    private static func collectionTitle(enrollment: Enrollment, on database: any Database) async throws -> Components.Schemas.LocalizedString {
        guard let publication = try await PublishedStudy.query(on: database)
            .filter(\.$study.$id == enrollment.$study.id)
            .filter(\.$revision == enrollment.currentRevision)
            .field(\.$metadata)
            .first() else { throw ServerError.internalServerError("Adopted study details are unavailable") }
        return publication.metadata.title
    }

    static func collectionWindows(
        _ timeline: [ConsentCollectionTimeline.Window], studyID: UUID, on database: any Database
    ) async throws -> [Components.Schemas.ConsentCollectionWindow] {
        guard !timeline.isEmpty else {
            return []
        }
        // Only collection policy is needed, not the retained consent text or archive.
        let records = try await PublishedStudy.query(on: database)
            .filter(\.$id ~~ timeline.map { $0.acceptance.publicationID })
            .field(\.$id)
            .field(\.$study.$id)
            .field(\.$revision)
            .field(\.$collectionPolicy)
            .all()
        let publications = try Dictionary(uniqueKeysWithValues: records.map { (try $0.requireID(), $0) })
        return try timeline.map { window in
            let consent = window.acceptance
            guard let publication = publications[consent.publicationID],
                  publication.$study.id == studyID, publication.revision == consent.revision else {
                throw ServerError.internalServerError("Exact collection policy is unavailable")
            }
            let requirements = try publication.collectionPolicy.resolvedRequirements(
                studyID: studyID,
                revision: consent.revision,
                acceptedAt: consent.acceptedAt,
                scope: consent.collectionScope,
                adoptionEnd: window.end
            )
            return .init(
                consentId: consent.consentID.uuidString.lowercased(),
                publicationId: consent.publicationID.uuidString.lowercased(),
                revision: consent.revision,
                start: consent.acceptedAt,
                end: window.end,
                requirements: requirements.map {
                    .init(
                        includeWorkoutRoutes: $0.includeWorkoutRoutes,
                        profile: $0.profile,
                        sourceTypeIdentifier: $0.sourceTypeIdentifier,
                        providerRegistrationId: $0.providerRegistrationID?.uuidString.lowercased(),
                        sourceKind: $0.sourceKind == .participantApp ? .participantApp : .serverWorker,
                        start: $0.start,
                        end: $0.end,
                        timeBasis: $0.timeBasis
                    )
                }
            )
        }
    }
}


extension Controller {
    func getParticipantCollectionPlan(
        _ input: Operations.GetParticipantCollectionPlan.Input
    ) async throws -> Operations.GetParticipantCollectionPlan.Output {
        let plan = try await consentService.collectionPlan(enrollmentID: input.path.enrollmentId.requireId())
        return .ok(.init(headers: .init(cacheControl: .noStore), body: .json(plan)))
    }
}
