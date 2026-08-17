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


final class ConsentService: Module, @unchecked Sendable {
    @Dependency(ConsentRepository.self) var repository
    @Dependency(AuthorizationService.self) var authorizationService
    @Dependency(EnrollmentRepository.self) var enrollmentRepository
    @Dependency(PublishedStudyRepository.self) var publishedStudyRepository
    @Dependency(ObjectStorageService.self) var storageService

    func listConsents(enrollmentId: UUID) async throws -> [EnrollmentConsent] {
        let enrollment = try await authorizationService.checkParticipantHasEnrollmentAccess(id: enrollmentId)
        return try await repository.listConsentRecords(enrollmentId: try enrollment.requireId())
    }

    func getConsentPdfKey(enrollmentId: UUID, consentId: UUID) async throws -> String {
        let enrollment = try await authorizationService.checkParticipantHasEnrollmentAccess(id: enrollmentId)
        let consent = try await repository.findConsentRecord(id: consentId, enrollmentId: try enrollment.requireId())
        guard let consent else {
            throw ServerError.notFound("Consent record not found")
        }
        return "consents/\(enrollment.$study.id)/\(try enrollment.requireId())/\(consent.revision).pdf"
    }

    func createConsent(enrollmentId: UUID, userResponses: UserResponses, pdfData: Data) async throws -> EnrollmentConsent {
        let enrollment = try await authorizationService.checkParticipantHasEnrollmentAccess(id: enrollmentId)
        let enrollmentUUID = try enrollment.requireId()

        if enrollment.withdrawnAt != nil {
            throw ServerError.conflict("Cannot submit consent for a withdrawn enrollment")
        }

        let studyId = enrollment.$study.id
        guard let latestPublished = try await publishedStudyRepository.findLatestPublished(forStudyId: studyId) else {
            throw ServerError.notFound(resource: "PublishedStudy", identifier: studyId.uuidString)
        }
        let targetRevision = max(latestPublished.revision, enrollment.currentRevision)

        let pdfKey = "consents/\(studyId)/\(enrollmentUUID)/\(targetRevision).pdf"
        try await storageService.upload(data: pdfData, key: pdfKey, contentType: "application/pdf")

        let record = EnrollmentConsent(
            enrollmentId: enrollmentUUID,
            revision: targetRevision,
            userResponses: userResponses
        )

        let saved: EnrollmentConsent
        do {
            saved = try await repository.createConsentRecord(record)
        } catch where (error as? any DatabaseError)?.isConstraintFailure == true {
            throw ServerError.conflict("Consent already submitted for this enrollment revision")
        }

        if enrollment.currentRevision != targetRevision {
            enrollment.currentRevision = targetRevision
            _ = try await enrollmentRepository.update(enrollment)
        }

        return saved
    }
}
