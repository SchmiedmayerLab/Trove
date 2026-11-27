// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation


/// The exact archived definitions of one published revision, read once per export.
struct TaskExportPublication {
    let revision: Int
    let questionnaires: [UUID: (canonical: String, bytes: Data)]
    let graph: Data

    /// - Parameter instruments: The instruments of every exported occurrence of this revision.
    static func load(
        _ instruments: [PublishedStudyService.TaskInstrument], objects: TaskExportObjects, using artifacts: ArtifactStore
    ) async throws -> Self {
        guard let instrument = instruments.first,
              instruments.allSatisfy({ $0.publicationID == instrument.publicationID && $0.revision == instrument.revision }),
              let publication = try await PublishedStudy.find(instrument.publicationID, on: artifacts.database),
              publication.$study.id == instrument.studyID, publication.revision == instrument.revision,
              publication.artifactID == instrument.artifactID else { throw ServerError.forbidden }
        let archive = try await objects.bytes(
            id: instrument.artifactID,
            ownerID: instrument.studyID,
            purpose: .publication,
            expected: (publication.bundleKey, publication.bundleDigest),
            using: artifacts
        )
        guard let graph = try StudyBundleService.taskDefinitions(in: archive, study: instrument.studyID) else {
            throw ServerError.conflict("The published revision has no task definitions")
        }
        var questionnaires: [UUID: (canonical: String, bytes: Data)] = [:]
        for component in Dictionary(grouping: instruments, by: \.componentID).values {
            guard let first = component.first, component.allSatisfy({ $0 == first }) else { throw ServerError.forbidden }
            let bytes = try StudyBundleService.publishedQuestionnaire(
                in: archive,
                studyID: first.studyID,
                componentID: first.componentID,
                baseLanguage: first.baseLanguage,
                sha256: first.sha256
            )
            let resource = try StudyProjectionJSON.readResult(bytes)
            guard resource["resourceType"]?.string == "Questionnaire", let url = resource["url"]?.string,
                  let version = resource["version"]?.string else { throw ServerError.forbidden }
            let canonical = url + "|" + version
            _ = try StudyTaskDefinitions.resolve(
                graph, study: first.studyID, revision: first.revision, component: first.componentID, questionnaire: canonical
            )
            questionnaires[first.componentID] = (canonical, bytes)
        }
        return .init(revision: instrument.revision, questionnaires: questionnaires, graph: graph)
    }
}
