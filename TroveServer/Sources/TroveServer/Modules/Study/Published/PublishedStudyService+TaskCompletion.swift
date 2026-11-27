// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import Logging
import TroveAPIServer


extension PublishedStudyService {
    /// Publication references from a participant's retained occurrence and authorized enrollment.
    struct TaskInstrument: Codable, Sendable, Equatable {
        let studyID: UUID
        let publicationID: UUID
        let revision: Int
        let artifactID: UUID
        let componentID: UUID
        let baseLanguage: String
        let sha256: String
    }

    /// Runs outside the enrollment transaction. Acceptance rechecks the occurrence and session against these inputs.
    ///
    /// Grove's pair rules check the response against the exact published Questionnaire bytes. The reusable validator
    /// engine then checks the response's own structure, as for other participant events; it throws when the engine
    /// rejects the bytes or is unavailable.
    func checkTaskResponse(
        instrument: TaskInstrument, sessionLanguage: LanguageTag, response: Data
    ) async throws -> QuestionnaireResponseValidationService.Result {
        guard response.count <= FHIRValidationClient.maximumBytes else { throw TaskResultEvidence.tooLarge }
        guard let publication = try await repository.find(studyId: instrument.studyID, revision: instrument.revision),
              try publication.requireId() == instrument.publicationID, publication.artifactID == instrument.artifactID else {
            throw ServerError.internalServerError("The task's published instrument is unavailable")
        }
        let questionnaire = try await publishedQuestionnaire(instrument, of: publication)
        let result = QuestionnaireResponseValidationService.validateCompletion(
            questionnaire: questionnaire, response: response, language: sessionLanguage
        )
        guard result.status == .valid else {
            return result
        }
        do {
            _ = try await validationService.validator.validateResponseStructure(response)
        } catch let error as ServerError where error.status == .unprocessableContent {
            throw ServerError(status: .unprocessableContent, title: "Invalid task response", detail: "The response did not pass the task checks")
        }
        return result
    }

    /// Reads the pinned Questionnaire from the derived artifact cache of the publication archive. A miss or a digest
    /// mismatch extracts it from the archive once and writes it back.
    func publishedQuestionnaire(_ instrument: TaskInstrument, of publication: PublishedStudy) async throws -> Data {
        try await DerivedArtifactCache(storage: storageService).entry(
            source: publication.bundleDigest,
            kind: .questionnaire,
            content: instrument.sha256,
            maximumBytes: ArtifactReference.Purpose.publication.maximumBytes
        ) {
            try StudyBundleService.publishedQuestionnaire(
                in: try await publicationBytes(publication),
                studyID: instrument.studyID,
                componentID: instrument.componentID,
                baseLanguage: instrument.baseLanguage,
                sha256: instrument.sha256
            )
        }
    }

    /// Writes every scheduled Questionnaire of an accepted publication to the derived artifact cache, so completions
    /// read it without unpacking the archive. A failure leaves the entries to be written on first use.
    func prefillQuestionnaires(of publication: PublishedStudy) async {
        let cache = DerivedArtifactCache(storage: storageService)
        do {
            let archive = try await publicationBytes(publication)
            var written = Set<String>()
            for plan in publication.taskPlan.schedules where written.insert(plan.questionnaireSHA256).inserted {
                let bytes = try StudyBundleService.publishedQuestionnaire(
                    in: archive,
                    studyID: publication.$study.id,
                    componentID: plan.schedule.componentId,
                    baseLanguage: plan.language,
                    sha256: plan.questionnaireSHA256
                )
                try await cache.store(bytes, source: publication.bundleDigest, kind: .questionnaire)
            }
        } catch {
            Logger(label: "trove.publication").warning(
                "Questionnaires were not prefilled; completions derive them on first use", metadata: ["error": .string("\(type(of: error))")]
            )
        }
    }
}
