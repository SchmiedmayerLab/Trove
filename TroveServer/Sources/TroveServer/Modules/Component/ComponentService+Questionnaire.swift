//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import TroveAPITypes


/// Questionnaire components carry administration languages, and administrators approve each language for the exact
/// stored resource. Approvals never change the draft revision; publication validation reads them under the study lock.
extension ComponentService {
    struct QuestionnaireComponent: Sendable {
        let component: Component
        let approvals: [QuestionnaireLanguageApproval]
    }

    private static func questionnaire(id: UUID, studyID: UUID, on transaction: any Database) async throws -> Component {
        guard let component = try await ComponentRepository(database: transaction).find(id: id, studyId: studyID),
              component.type == .questionnaire else {
            throw ServerError.notFound(resource: "Component", identifier: id.uuidString)
        }
        return component
    }

    private static func withApprovals(_ component: Component, on transaction: any Database) async throws -> QuestionnaireComponent {
        guard case .questionnaire(let content) = component.data else {
            throw ServerError.internalServerError("Expected questionnaire component data")
        }
        let sha256 = FHIRValidationClient.digest(Data(content.questionnaire.utf8))
        let approvals = try await QuestionnaireLanguageApproval.inForce(componentIDs: [try component.requireId()], on: transaction)
        return .init(component: component, approvals: approvals.filter { $0.sha256 == sha256 })
    }

    private static func approvalInForce(
        componentID: UUID,
        sha256: String,
        language: String,
        on transaction: any Database
    ) async throws -> QuestionnaireLanguageApproval? {
        // swiftlint:disable:next first_where - Fluent query builder, not a Sequence
        try await QuestionnaireLanguageApproval.query(on: transaction)
            .filter(\.$componentID == componentID)
            .filter(\.$sha256 == sha256)
            .filter(\.$language == language)
            .filter(\.$revokedAt == nil)
            .first()
    }

    /// Requires that the component stores the resource with `sha256` and that `language` is one of its languages.
    private static func requireApprovable(_ component: Component, componentID: UUID, sha256: String, language: String) throws {
        guard case .questionnaire(let content) = component.data else {
            throw ServerError.notFound(resource: "Component", identifier: componentID.uuidString)
        }
        let bytes = Data(content.questionnaire.utf8)
        guard FHIRValidationClient.digest(bytes) == sha256 else {
            throw ServerError.conflict("The questionnaire changed; review the stored resource before approving it")
        }
        let languages = QuestionnaireLanguages(bytes)
        guard languages.base == language || languages.translations.contains(language) else {
            throw ServerError(
                status: .unprocessableContent,
                title: "Unknown Questionnaire Language",
                detail: "The language is neither the base language nor a translation language of the questionnaire"
            )
        }
    }

    func getQuestionnaire(studyID: UUID, id: UUID) async throws -> QuestionnaireComponent {
        try await studyService.readDraft(id: studyID) { _, transaction in
            let component = try await Self.questionnaire(id: id, studyID: studyID, on: transaction)
            return try await Self.withApprovals(component, on: transaction)
        }
    }

    /// A `nil` `administrationLanguages` admits the base language of the resource.
    func createQuestionnaire(
        studyID: UUID,
        expectedRevision: UUID,
        name: String,
        content: QuestionnaireContent,
        administrationLanguages: [String]? // swiftlint:disable:this discouraged_optional_collection
    ) async throws -> QuestionnaireComponent {
        let administration = try QuestionnaireAdministration.resolve(administrationLanguages, questionnaire: content)
        return try await studyService.editDraft(id: studyID, expectedRevision: expectedRevision) { _, transaction in
            let component = try await ComponentRepository(database: transaction).create(
                Component(studyId: studyID, data: .questionnaire(content), name: name, administration: administration)
            )
            return try await Self.withApprovals(component, on: transaction)
        }
    }

    /// A `nil` `administrationLanguages` admits the base language of the resource.
    func replaceQuestionnaire( // swiftlint:disable:this function_parameter_count
        studyID: UUID,
        id: UUID,
        expectedRevision: UUID,
        name: String,
        content: QuestionnaireContent,
        administrationLanguages: [String]? // swiftlint:disable:this discouraged_optional_collection
    ) async throws -> QuestionnaireComponent {
        let administration = try QuestionnaireAdministration.resolve(administrationLanguages, questionnaire: content)
        return try await studyService.editDraft(id: studyID, expectedRevision: expectedRevision) { _, transaction in
            let repository = ComponentRepository(database: transaction)
            let component = try await Self.questionnaire(id: id, studyID: studyID, on: transaction)
            component.name = name
            component.data = .questionnaire(content)
            component.administration = administration
            return try await Self.withApprovals(try await repository.update(component), on: transaction)
        }
    }

    /// Records an approval for the stored resource with `sha256`, or returns the one in force.
    func approveLanguage(
        studyID: UUID, componentID: UUID, sha256: String, language: String
    ) async throws -> (approval: QuestionnaireLanguageApproval, created: Bool) {
        guard sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (1...35).contains(language.count), !language.contains(where: \.isWhitespace) else {
            throw ServerError.badRequest("An approval names a lowercase hexadecimal SHA-256 digest and a language code of at most 35 characters")
        }
        let access = try await studyService.authorizationService.prepareDraftAccess(operation: .publish)
        return try await studyService.repository.database.transaction { transaction in
            let study = try await self.studyService.repository.lockStudy(id: studyID, on: transaction)
            let context = try await self.studyService.authorizationService.authorizeDraft(access, study: study, on: transaction)
            let component = try await Self.questionnaire(id: componentID, studyID: studyID, on: transaction)
            try Self.requireApprovable(component, componentID: componentID, sha256: sha256, language: language)
            let scope = AuditEvent.Scope.study(studyID: studyID, groupID: study.$group.id)
            if let existing = try await Self.approvalInForce(
                componentID: componentID,
                sha256: sha256,
                language: language,
                on: transaction
            ) {
                try await AuditRepository.recordDisclosureIntent(AuditEvent(
                    context: context, action: .studyDraftDisclosure, scope: scope, target: .init(id: studyID, version: study.draftRevision.uuidString)
                ), on: transaction)
                return (existing, false)
            }
            let approval = QuestionnaireLanguageApproval(
                studyID: studyID, componentID: componentID, sha256: sha256, language: language, approver: context.actor, approvedAt: Date()
            )
            try await approval.create(on: transaction)
            try await AuditRepository.recordMutation(AuditEvent(
                context: context, action: .studyLanguageApproved, scope: scope, target: .init(id: try approval.requireId(), version: sha256)
            ), on: transaction)
            // Return the stored timestamp, which publication copies, rather than the in-memory value.
            guard let stored = try await QuestionnaireLanguageApproval.find(try approval.requireId(), on: transaction) else {
                throw ServerError.internalServerError("The approval could not be reloaded")
            }
            return (stored, true)
        }
    }

    func revokeLanguageApproval(studyID: UUID, componentID: UUID, approvalID: UUID) async throws -> QuestionnaireLanguageApproval {
        let access = try await studyService.authorizationService.prepareDraftAccess(operation: .publish)
        return try await studyService.repository.database.transaction { transaction in
            let study = try await self.studyService.repository.lockStudy(id: studyID, on: transaction)
            let context = try await self.studyService.authorizationService.authorizeDraft(access, study: study, on: transaction)
            guard let approval = try await QuestionnaireLanguageApproval.find(approvalID, on: transaction),
                  approval.studyID == studyID, approval.componentID == componentID else {
                throw ServerError.notFound(resource: "Language approval", identifier: approvalID.uuidString)
            }
            let scope = AuditEvent.Scope.study(studyID: studyID, groupID: study.$group.id)
            guard approval.revokedAt == nil else {
                try await AuditRepository.recordDisclosureIntent(AuditEvent(
                    context: context, action: .studyDraftDisclosure, scope: scope, target: .init(id: studyID, version: study.draftRevision.uuidString)
                ), on: transaction)
                return approval
            }
            approval.revokedAt = Date()
            approval.revokedByIssuer = context.actor.issuer
            approval.revokedBySubject = context.actor.subject
            try await approval.update(on: transaction)
            try await AuditRepository.recordMutation(AuditEvent(
                context: context, action: .studyLanguageApprovalRevoked, scope: scope, target: .init(id: approvalID, version: approval.sha256)
            ), on: transaction)
            guard let stored = try await QuestionnaireLanguageApproval.find(approvalID, on: transaction) else {
                throw ServerError.internalServerError("The approval could not be reloaded")
            }
            return stored
        }
    }
}
