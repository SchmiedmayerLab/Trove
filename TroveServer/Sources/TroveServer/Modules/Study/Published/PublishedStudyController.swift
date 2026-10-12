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
        let candidate = try await studyValidationService.validate(
            studyID: input.path.studyId.requireId(), expectedRevision: DraftRevision.parse(ifMatch: input.headers.ifMatch)
        )
        return .created(.init(body: .json(try .init(
            id: candidate.requireId().uuidString,
            draftRevision: candidate.draftRevision.uuidString,
            publicationRevision: candidate.publicationRevision,
            bundleSha256: candidate.bundleDigest,
            validatorIdentity: candidate.validatorIdentity,
            contractRevision: candidate.contractRevision,
            executionCapability: candidate.executionCapability,
            createdAt: candidate.createdAt,
            expiresAt: candidate.expiresAt,
            questionnaires: candidate.snapshot.questionnaires.map {
                .init(componentId: $0.componentID.uuidString, locale: $0.locale, sha256: $0.validation.sha256)
            }
        ))))
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
