//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


extension Controller {
    func postStudiesStudyIdPublish(
        _ input: Operations.PostStudiesStudyIdPublish.Input
    ) async throws -> Operations.PostStudiesStudyIdPublish.Output {
        let studyId = try input.path.studyId.requireId()
        guard case .json(let request) = input.body else { throw ServerError.jsonBodyRequired }
        let published = try await publishedStudyService.publish(
            studyId: studyId,
            validationID: request.validationId.requireId(),
            expectedRevision: DraftRevision.parse(ifMatch: input.headers.ifMatch)
        )
        return .created(.init(body: .json(try .init(published))))
    }

    func validateStudyDraft(_ input: Operations.ValidateStudyDraft.Input) async throws -> Operations.ValidateStudyDraft.Output {
        let report = try await studyValidationService.validate(
            studyID: input.path.studyId.requireId(), expectedRevision: DraftRevision.parse(ifMatch: input.headers.ifMatch)
        )
        let body = Components.Schemas.StudyDraftValidation(
            draftRevision: report.draftRevision.uuidString,
            status: report.status,
            blockers: report.blockers,
            advisories: report.advisories,
            questionnaires: report.questionnaires.map { entry in
                let administration = report.administrations.first { $0.componentID == entry.componentID }
                return .init(
                    componentId: entry.componentID.uuidString,
                    status: entry.result.status,
                    language: entry.result.language,
                    translationLanguages: entry.result.translationLanguages,
                    sha256: entry.result.sha256,
                    administrationLanguages: (administration?.languages ?? []).map {
                        .init(
                            language: $0.language,
                            translationComplete: $0.translationComplete,
                            approved: $0.approval != nil,
                            approvalId: $0.approval?.id?.uuidString
                        )
                    }
                )
            },
            candidate: try report.candidate.map {
                .init(
                    id: try $0.requireId().uuidString,
                    publicationRevision: $0.publicationRevision,
                    bundleSha256: $0.bundleDigest,
                    validatorIdentity: $0.validatorIdentity,
                    contractRevision: $0.contractRevision,
                    executionCapability: $0.executionCapability,
                    createdAt: $0.createdAt,
                    expiresAt: $0.expiresAt
                )
            },
            routes: report.routes.map(Components.Schemas.StudyRouteValidation.init)
        )
        return body.candidate == nil ? .ok(.init(body: .json(body))) : .created(.init(body: .json(body)))
    }

    func getStudiesStudyIdPublished(
        _ input: Operations.GetStudiesStudyIdPublished.Input
    ) async throws -> Operations.GetStudiesStudyIdPublished.Output {
        let studyId = try input.path.studyId.requireId()
        let published = try await publishedStudyService.listPublished(studyId: studyId)
        return .ok(.init(body: .json(try published.map { try .init($0) })))
    }

    func getParticipantStudies(
        _ input: Operations.GetParticipantStudies.Input
    ) async throws -> Operations.GetParticipantStudies.Output {
        let studyId = try input.query.studyId?.requireId()
        let studies = try await publishedStudyService.browseStudies(studyId: studyId)
        return .ok(.init(body: .json(try studies.map { try .init($0) })))
    }
}
