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
        let administrations: [QuestionnaireAdministrationCheck]
        let routes: [CollectionRouteAvailability]
        let candidate: StudyPublicationCandidate?
    }

    /// One draft captured under the study lock, with the authority-relevant state read in the same transaction.
    private struct Capture {
        let study: Study
        let publicationRevision: Int
        let approvals: [QuestionnaireLanguageApproval]
        let routes: [CollectionRouteAvailability]
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

    func validate(studyID: UUID, expectedRevision: UUID) async throws -> Report {
        let capture = try await capture(studyID: studyID, expectedRevision: expectedRevision)
        let study = capture.study
        let createdAt = Date()
        let questionnaires = try await validateQuestionnaires(in: study, at: createdAt)
        let administrations = try Self.administrationChecks(study: study, approvals: capture.approvals)
        let (status, findings) = outcome(
            study: study,
            questionnaires: questionnaires,
            administrations: administrations,
            routes: capture.routes
        )
        // Each result that is not valid carries an error finding that says why, so errors are exactly the blockers.
        let blockers = findings.filter { $0.severity == .error }
        let advisories = findings.filter { $0.severity != .error }
        guard status == .valid else {
            try await authorizeReport(studyID: studyID, revision: expectedRevision)
            return Report(
                draftRevision: expectedRevision,
                status: status,
                blockers: blockers,
                advisories: advisories,
                questionnaires: questionnaires,
                administrations: administrations,
                routes: capture.routes,
                candidate: nil
            )
        }
        let candidate = try await stage(
            study,
            publicationRevision: capture.publicationRevision,
            expectedRevision: expectedRevision,
            questionnaires: questionnaires,
            administrations: administrations,
            unavailable: capture.routes.filter { !$0.available }.map(\.requirement),
            at: createdAt
        )
        return Report(
            draftRevision: expectedRevision,
            status: .valid,
            blockers: [],
            advisories: advisories,
            questionnaires: questionnaires,
            administrations: administrations,
            routes: capture.routes,
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
        try await authorizeReport(studyID: studyID, revision: draftRevision)
        return (draftRevision, result)
    }

    private func authorizeReport(studyID: UUID, revision: UUID) async throws {
        try await studyService.readDraft(id: studyID, operation: .validate) { current, _ in
            try current.requireDraftRevision(revision)
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func stage(
        _ study: Study,
        publicationRevision: Int,
        expectedRevision: UUID,
        questionnaires: [Report.Questionnaire],
        administrations: [QuestionnaireAdministrationCheck],
        unavailable: [CollectionRequirement],
        at createdAt: Date
    ) async throws -> StudyPublicationCandidate {
        let studyID = try study.requireId()
        let identity = try validator.requireIdentity()
        let publication = try bundleService.preparePublication(from: study, revision: publicationRevision, unavailable: unavailable)
        let evidence = try Self.evidence(for: publication, questionnaires: questionnaires)
        let instruments = try Self.instruments(for: evidence, administrations: administrations)
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
                questionnaires: evidence,
                instruments: instruments,
                readinessFacts: study.readinessFacts,
                definitionSchemaVersion: PublicationEvidence.currentDefinitionSchemaVersion,
                contractVersion: FHIRValidationClient.contractVersion
            ),
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        return try await persist(candidate)
    }

    private func capture(studyID: UUID, expectedRevision: UUID) async throws -> Capture {
        let access = try await authorizationService.prepareDraftAccess(operation: .validate)
        return try await repository.database.transaction { transaction in
            let locked = try await self.repository.lockStudy(id: studyID, on: transaction)
            let context = try await self.authorizationService.authorizeDraft(access, study: locked, on: transaction)
            try locked.requireDraftRevision(expectedRevision)
            guard let snapshot = try await self.repository.loadWithComponentsAndSchedules(id: studyID, on: transaction) else {
                throw ServerError.notFound("Study draft not found")
            }
            let routes = try await self.providerRuntime.registrations.routes(for: snapshot.collectionRequirements, on: transaction)
            let questionnaireIDs = try (snapshot.$components.value ?? []).filter { $0.type == .questionnaire }.map { try $0.requireId() }
            let approvals = try await QuestionnaireLanguageApproval.inForce(componentIDs: questionnaireIDs, on: transaction)
            try await AuditRepository.recordDisclosureIntent(AuditEvent(
                context: context,
                action: .studyDraftDisclosure,
                scope: .study(studyID: studyID, groupID: locked.$group.id),
                target: .init(id: studyID, version: expectedRevision.uuidString)
            ), on: transaction)
            return Capture(
                study: snapshot,
                publicationRevision: try await Self.nextPublicationRevision(studyID: studyID, on: transaction),
                approvals: approvals,
                routes: routes
            )
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
            try await Self.requireApprovals(candidate.snapshot.instruments, on: transaction)
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


extension StudyValidationService {
    static func nextPublicationRevision(studyID: UUID, on transaction: any Database) async throws -> Int {
        guard transaction.inTransaction else { throw AuditError.transactionRequired }
        let maximum = try await PublishedStudy.query(on: transaction).filter(\.$study.$id == studyID).max(\.$revision) ?? 0
        guard maximum < Int.max else { throw ServerError.conflict("The study publication revision cannot advance") }
        return maximum + 1
    }

    private static func administrationChecks(study: Study, approvals: [QuestionnaireLanguageApproval]) throws -> [QuestionnaireAdministrationCheck] {
        try (study.$components.value ?? []).sorted { ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "") }.compactMap { component in
            guard case .questionnaire(let content) = component.data else {
                return nil
            }
            let bytes = Data(content.questionnaire.utf8)
            // Approval reads the stored JSON the same way, so both name the same languages.
            let languages = QuestionnaireLanguages(bytes)
            return QuestionnaireAdministrationCheck(
                componentID: try component.requireId(),
                bytes: bytes,
                administration: component.administration,
                base: languages.base,
                translations: languages.translations,
                approvals: approvals
            )
        }
    }

    /// Every approval a candidate recorded is still in force for the same resource and language.
    static func requireApprovals(_ instruments: [PublishedInstrument], on transaction: any Database) async throws {
        guard transaction.inTransaction else { throw AuditError.transactionRequired }
        for instrument in instruments {
            for language in instrument.administrationLanguages {
                guard let approval = try await QuestionnaireLanguageApproval.find(language.approvalID, on: transaction),
                      approval.revokedAt == nil, approval.componentID == instrument.componentID,
                      approval.sha256 == instrument.sha256, approval.language == language.language else {
                    throw ServerError.conflict("A language approval changed after validation; validate the draft again")
                }
            }
        }
    }

    /// The archive holds each component's stored bytes, so the validated digests describe it exactly.
    private static func evidence(
        for publication: StudyBundleService.Publication,
        questionnaires: [Report.Questionnaire]
    ) throws -> [StudyPublicationCandidate.QuestionnaireEvidence] {
        try publication.questionnaires.map { resource in
            guard let validation = questionnaires.first(where: { $0.componentID == resource.componentID })?.result.evidence,
                  validation.sha256 == FHIRValidationClient.digest(resource.bytes) else {
                throw ServerError.internalServerError("Validated questionnaire bytes differ from the archive")
            }
            return StudyPublicationCandidate.QuestionnaireEvidence(componentID: resource.componentID, validation: validation)
        }
    }

    private static func instruments(
        for evidence: [StudyPublicationCandidate.QuestionnaireEvidence],
        administrations: [QuestionnaireAdministrationCheck]
    ) throws -> [PublishedInstrument] {
        try evidence.map { entry in
            guard let administration = administrations.first(where: { $0.componentID == entry.componentID }),
                  administration.sha256 == entry.validation.sha256 else {
                throw ServerError.internalServerError("Administration languages describe different questionnaire bytes")
            }
            return PublishedInstrument(
                componentID: entry.componentID,
                sha256: entry.validation.sha256,
                language: entry.validation.language,
                translationLanguages: entry.validation.translationLanguages,
                administrationLanguages: try administration.languages.map { language in
                    guard language.translationComplete, let approval = language.approval else {
                        throw ServerError.internalServerError("An unapproved administration language reached staging")
                    }
                    return .init(
                        language: language.language,
                        approvalID: try approval.requireId(),
                        approvedAt: approval.approvedAt,
                        approvedBy: .init(issuer: approval.approvedByIssuer, subject: approval.approvedBySubject)
                    )
                }
            )
        }
    }

    /// The combined status and every finding of one captured draft.
    private func outcome(
        study: Study,
        questionnaires: [Report.Questionnaire],
        administrations: [QuestionnaireAdministrationCheck],
        routes: [CollectionRouteAvailability]
    ) -> (status: ValidationStatus, findings: [ValidationDiagnostic]) {
        let details = StudyBundleService.detailLanguageDiagnostics(study.details.content.keys)
        // Readiness, administration languages and routes are Trove's own publication rules.
        let publication = StudyReadinessCheck.diagnostics(details: study.details, facts: study.readinessFacts)
            + administrations.flatMap(\.diagnostics)
            + routes.compactMap(\.diagnostic)
        var statuses = questionnaires.map(\.result.status) + [details.isEmpty ? .valid : .invalid]
        statuses.append(publication.contains { $0.severity == .error } ? .invalid : .valid)
        var findings = questionnaires.flatMap { entry in entry.result.diagnostics.map { $0.concerning(component: entry.componentID) } }
        findings += details + publication
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
        return (ValidationStatus.combined(statuses), findings)
    }
}
