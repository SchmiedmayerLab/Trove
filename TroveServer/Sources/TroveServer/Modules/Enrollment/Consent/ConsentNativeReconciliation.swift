//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import GroveHealthKit
import SQLKit
import TroveAPIServer


extension ConsentService {
    func nativeReconciliations(
        enrollmentID: UUID,
        sourceID: UUID,
        proof: SourceInstallationProof,
        configuration: NativeReconciliationSettings
    ) async throws -> [Components.Schemas.NativeCollectionReconciliationInstruction] {
        let context = try AuthContext.checkIsParticipant()
        let owned = try await authorizationService.checkParticipantHasEnrollmentAccess(id: enrollmentID)
        let study = try await verifiedStudyContext(enrollment: owned)
        return try await repository.database.transaction { transaction in
            let participantID = try await SourceBindingService.lockParticipant(context, on: transaction)
            guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            _ = try await Self.reconciliationSource(id: sourceID, participantID: participantID, proof: proof, on: transaction)
            let enrollment = try await self.repository.lockEnrollment(id: enrollmentID, on: transaction)
            guard enrollment.$participant.id == participantID else { throw ServerError.notFound("Enrollment not found") }
            let now = Date()
            let instructions: [Components.Schemas.NativeCollectionReconciliationInstruction]
            if enrollment.withdrawnAt == nil, enrollment.endsAt.map({ $0 <= now }) == true {
                let timeline = try await ConsentCollectionTimeline.load(enrollment: enrollment, on: transaction, asOf: now)
                let windows = try await Self.collectionWindows(timeline, studyID: enrollment.$study.id, on: transaction)
                instructions = try await Self.issueReconciliations(
                    windows, enrollment: enrollment, sourceID: sourceID, now: now, leaseDuration: configuration.leaseDuration, on: sql
                )
            } else {
                instructions = []
            }
            try await AuditRepository.recordMutation(.init(
                context: study.audit,
                action: .collectionReconciliationIssued,
                scope: .study(studyID: study.scope.studyID, groupID: study.scope.groupID),
                target: .init(id: enrollmentID)
            ), on: transaction)
            return instructions
        }
    }
}


extension ConsentService {
    static func reconciliationSource(
        id: UUID, participantID: UUID, proof: SourceInstallationProof, on database: any Database
    ) async throws -> SourceBinding {
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        guard let row = try await sql.raw("""
            SELECT * FROM source_bindings WHERE id = \(bind: id) AND participant_id = \(bind: participantID)
            """)
            .first() else { throw ServerError.notFound("Source binding not found") }
        let source = try SourceBinding(row: row)
        guard source.kind == .participantApp, source.repositoryKind == .healthKit else {
            throw ServerError.notFound("HealthKit source binding not found")
        }
        _ = try await proof.validate(source: source, on: database)
        return source
    }

    // swiftlint:disable:next function_parameter_count
    private static func issueReconciliations(
        _ windows: [Components.Schemas.ConsentCollectionWindow],
        enrollment: Enrollment,
        sourceID: UUID,
        now: Date,
        leaseDuration: TimeInterval,
        on database: any SQLDatabase
    ) async throws -> [Components.Schemas.NativeCollectionReconciliationInstruction] {
        let store = NativeCollectionReconciliationStore(database: database, participantID: enrollment.$participant.id)
        let expiresAt = now.addingTimeInterval(leaseDuration)
        guard CollectionMeasurementWindow.valid(expiresAt), now < expiresAt else { throw ServerError.unexpectedError }
        var result: [Components.Schemas.NativeCollectionReconciliationInstruction] = []
        for window in windows {
            for requirement in window.requirements {
                for source in reconciliationSources(requirement) {
                    guard let end = requirement.end, requirement.start < end, end <= now else { continue }
                    let candidate = Components.Schemas.NativeCollectionReconciliationInstruction(
                        id: UUID().uuidString.lowercased(),
                        sourceId: sourceID.uuidString.lowercased(),
                        enrollmentId: try enrollment.requireID().uuidString.lowercased(),
                        studyId: enrollment.$study.id.uuidString.lowercased(),
                        stateVersion: enrollment.stateVersion,
                        issuedAt: now,
                        expiresAt: expiresAt,
                        consentId: window.consentId,
                        publicationId: window.publicationId,
                        revision: window.revision,
                        profile: source.profile,
                        sourceTypeIdentifier: source.token,
                        start: requirement.start,
                        end: end,
                        includeWorkoutRoutes: requirement.includeWorkoutRoutes ?? false
                    )
                    if let instruction = try await store.issue(candidate) { result.append(instruction) }
                    guard result.count <= 256 else { throw ServerError.conflict("Too many unfinished collection reconciliations") }
                }
            }
        }
        return result
    }

    private static func reconciliationSources(_ requirement: Components.Schemas.CollectionPlanRequirement) -> [(profile: String, token: String)] {
        guard requirement.sourceKind == .participantApp, (requirement.timeBasis ?? .measurementTime) == .measurementTime,
              let profile = CollectionObservationProfile(rawValue: requirement.profile), profile == .sleepStage || profile == .workout,
              let token = profile.nativeSourceTypeIdentifier,
              profile.matchesSource(expected: requirement.sourceTypeIdentifier, actual: token) else { return [] }
        var result = [(profile: profile.rawValue, token: token)]
        if profile == .workout, requirement.includeWorkoutRoutes == true {
            result.append((CollectionObservationProfile.healthKitRecording.rawValue, SampleType.workoutRoute.hkSampleType.identifier))
        }
        return result
    }
}
