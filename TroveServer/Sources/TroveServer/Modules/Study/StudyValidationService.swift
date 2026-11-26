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


/// Validates one captured draft and, when it is valid, records a short-lived, immutable publication candidate.
/// Validator and object-storage requests never run while holding a database transaction.
final class StudyValidationService: Module, @unchecked Sendable {
    /// The outcome of validating one exact draft. Only a `valid` report carries a candidate.
    struct Report: Sendable {
        struct Questionnaire: Sendable {
            let componentID: UUID
            let result: QuestionnaireValidationService.Result
        }

        let draftRevision: UUID
        let status: ValidationStatus
        let blockers: [ValidationDiagnostic]
        let advisories: [ValidationDiagnostic]
        let questionnaires: [Questionnaire]
        let candidate: StudyPublicationCandidate?
    }

    @Dependency(StudyRepository.self) var repository
    @Dependency(AuthorizationService.self) var authorizationService
    @Dependency(StudyBundleService.self) var bundleService
    @Dependency(ObjectStorageService.self) var storageService
    @Dependency(ProviderRuntime.self) var providerRuntime
    @Dependency(StudyService.self) var studyService

    let validator: FHIRValidationClient

    init(validator: FHIRValidationClient) {
        self.validator = validator
    }

    static func nextPublicationRevision(studyID: UUID, on transaction: any Database) async throws -> Int {
        guard transaction.inTransaction else { throw AuditError.transactionRequired }
        let maximum = try await PublishedStudy.query(on: transaction).filter(\.$study.$id == studyID).max(\.$revision) ?? 0
        guard maximum < Int.max else { throw ServerError.conflict("The study publication revision cannot advance") }
        return maximum + 1
    }

    func validate(studyID: UUID, expectedRevision: UUID) async throws -> Report {
        let (study, publicationRevision) = try await capture(studyID: studyID, expectedRevision: expectedRevision)
        let createdAt = Date()
        let questionnaires = try await validateQuestionnaires(in: study, at: createdAt)
        let details = StudyBundleService.detailLanguageDiagnostics(study.details.content.keys)
        var statuses = questionnaires.map(\.result.status) + [details.isEmpty ? .valid : .invalid]
        var findings = questionnaires.flatMap { entry in entry.result.diagnostics.map { $0.concerning(component: entry.componentID) } }
        findings += details
        if (try? validator.requireIdentity()) == nil {
            // Every candidate, with or without questionnaires, names the pinned validator.
            if !statuses.contains(.unavailable) {
                findings.append(.trove(
                    "validator-unavailable",
                    path: "",
                    message: "No pinned FHIR validator is configured, so no candidate can be created.",
                    nextAction: "Validate again once the validator is available."
                ))
            }
            statuses.append(.unavailable)
        }
        let status = ValidationStatus.combined(statuses)
        // Each result that is not valid carries an error finding that says why, so errors are exactly the blockers.
        let blockers = findings.filter { $0.severity == .error }
        let advisories = findings.filter { $0.severity != .error }
        guard status == .valid else {
            return Report(
                draftRevision: expectedRevision,
                status: status,
                blockers: blockers,
                advisories: advisories,
                questionnaires: questionnaires,
                candidate: nil
            )
        }
        let candidate = try await stage(
            study, publicationRevision: publicationRevision, expectedRevision: expectedRevision, questionnaires: questionnaires, at: createdAt
        )
        return Report(
            draftRevision: expectedRevision,
            status: .valid,
            blockers: [],
            advisories: advisories,
            questionnaires: questionnaires,
            candidate: candidate
        )
    }

    /// Validates one questionnaire component's stored resource without staging or recording anything.
    func validateComponent(studyID: UUID, componentID: UUID) async throws -> (draftRevision: UUID, result: QuestionnaireValidationService.Result) {
        let (draftRevision, content) = try await studyService.readQuestionnaire(
            studyID: studyID, componentID: componentID, operation: .validate, purpose: "validation"
        )
        let result = try await QuestionnaireValidationService(validator: validator)
            .validate(bytes: Data(content.questionnaire.utf8), evaluationInstant: Date())
        return (draftRevision, result)
    }

    private func stage(
        _ study: Study, publicationRevision: Int, expectedRevision: UUID, questionnaires: [Report.Questionnaire], at createdAt: Date
    ) async throws -> StudyPublicationCandidate {
        let studyID = try study.requireId()
        let identity = try validator.requireIdentity()
        let publication = try bundleService.preparePublication(from: study, revision: publicationRevision)
        // The archive holds each component's stored bytes, so the validated digests describe it exactly.
        let evidence = try publication.questionnaires.map { resource in
            guard let validation = questionnaires.first(where: { $0.componentID == resource.componentID })?.result.evidence,
                  validation.sha256 == FHIRValidationClient.digest(resource.bytes) else {
                throw ServerError.internalServerError("Validated questionnaire bytes differ from the archive")
            }
            return StudyPublicationCandidate.QuestionnaireEvidence(componentID: resource.componentID, validation: validation)
        }
        let expiresAt = evidence.compactMap { $0.validation.validUntil }.reduce(createdAt.addingTimeInterval(3600), min)
        try Task.checkCancellation()
        guard expiresAt > Date() else { throw ServerError.conflict("Questionnaire eligibility expired during validation") }
        let artifact = try await ArtifactStore(database: repository.database, storage: storageService).stage(
            publication.bundle,
            purpose: .publication,
            ownerID: studyID,
            scope: .init(studyID: studyID, groupID: study.$group.id),
            now: createdAt
        )
        let candidate = StudyPublicationCandidate(
            studyID: studyID,
            groupID: study.$group.id,
            draftRevision: expectedRevision,
            publicationRevision: publicationRevision,
            artifact: artifact,
            validatorIdentity: identity,
            snapshot: .init(
                metadata: publication.metadata,
                consent: publication.consent,
                visibility: publication.visibility,
                enrollmentCondition: publication.enrollmentCondition,
                collectionPolicy: publication.collectionPolicy,
                questionnaires: evidence
            ),
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        return try await persist(candidate)
    }

    private func capture(studyID: UUID, expectedRevision: UUID) async throws -> (Study, Int) {
        let access = try await authorizationService.prepareDraftAccess(operation: .validate)
        return try await repository.database.transaction { transaction in
            let locked = try await self.repository.lockStudy(id: studyID, on: transaction)
            let context = try await self.authorizationService.authorizeDraft(access, study: locked, on: transaction)
            try locked.requireDraftRevision(expectedRevision)
            guard let snapshot = try await self.repository.loadWithComponentsAndSchedules(id: studyID, on: transaction) else {
                throw ServerError.notFound("Study draft not found")
            }
            try await self.providerRuntime.registrations.validate(requirements: snapshot.collectionRequirements, on: transaction)
            try await AuditRepository.recordDisclosureIntent(AuditEvent(
                context: context,
                action: .studyDraftDisclosure,
                scope: .study(studyID: studyID, groupID: locked.$group.id),
                target: .init(id: studyID, version: expectedRevision.uuidString)
            ), on: transaction)
            return (snapshot, try await Self.nextPublicationRevision(studyID: studyID, on: transaction))
        }
    }

    private func validateQuestionnaires(in study: Study, at instant: Date) async throws -> [Report.Questionnaire] {
        let questionnaires = QuestionnaireValidationService(validator: validator)
        var results: [Report.Questionnaire] = []
        var deadline = instant.addingTimeInterval(3600)
        let components = (study.$components.value ?? []).sorted { ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "") }
        for component in components {
            guard case .questionnaire(let content) = component.data else {
                continue
            }
            try Task.checkCancellation()
            guard Date() < deadline else { throw ServerError.conflict("Study validation expired before all resources could be checked") }
            let result = try await questionnaires.validate(bytes: Data(content.questionnaire.utf8), evaluationInstant: instant)
            results.append(.init(componentID: try component.requireId(), result: result))
            if let validUntil = result.evidence?.validUntil {
                deadline = min(deadline, validUntil)
            }
        }
        return results
    }

    private func persist(_ candidate: StudyPublicationCandidate) async throws -> StudyPublicationCandidate {
        // A remote validation may take longer than the authorization freshness window.
        let access = try await authorizationService.prepareDraftAccess(operation: .validate)
        return try await repository.database.transaction { transaction in
            let current = try await self.repository.lockStudy(id: candidate.studyID, on: transaction)
            let context = try await self.authorizationService.authorizeDraft(access, study: current, on: transaction)
            try current.requireDraftRevision(candidate.draftRevision)
            guard current.$group.id == candidate.groupID,
                  try await Self.nextPublicationRevision(studyID: candidate.studyID, on: transaction) == candidate.publicationRevision else {
                throw ServerError.conflict("Publication state changed during validation; validate again")
            }
            try candidate.requireCurrentEvidence(validatorIdentity: self.validator.expectedIdentity, now: Date())
            try await candidate.create(on: transaction)
            try await AuditRepository.recordMutation(AuditEvent(
                context: context,
                action: .studyDraftValidated,
                scope: .study(studyID: candidate.studyID, groupID: candidate.groupID),
                target: .init(id: candidate.requireId(), version: candidate.draftRevision.uuidString)
            ), on: transaction)
            return candidate
        }
    }
}
