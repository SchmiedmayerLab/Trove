//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import GroveFoundation
import GroveLocalization
@_spi(APISupport) import GroveStudyDefinition
import TroveAPIServer
import ZIPFoundation


final class StudyBundleService: Module, @unchecked Sendable {
    struct QuestionnaireResource: Sendable {
        let componentID: UUID
        let locale: String
        let bytes: Data
    }

    struct Publication: Sendable {
        let metadata: StudyDefinition.Metadata
        let consent: LocalizationsDictionary<String>
        let visibility: StudyVisibility
        let enrollmentCondition: EnrollmentConditions
        let collectionPolicy: PublishedCollectionPolicy
        let groupID: UUID
        let bundle: Data
        let questionnaires: [QuestionnaireResource]
    }

    @Dependency(AuthorizationService.self) var authorizationService
    @Dependency(StudyRepository.self) var studyRepository

    func buildBundle(studyId: UUID, revision: Int) async throws -> Data {
        try await preparePublication(studyId: studyId, revision: revision).bundle
    }

    /// One captured draft supplies both database metadata and the immutable archive.
    func preparePublication(studyId: UUID, revision: Int) async throws -> Publication {
        guard revision > 0 else {
            throw ServerError.badRequest("Study revision must be positive")
        }
        try await authorizationService.checkResearcherHasStudyAccess(studyId, role: .researcher)
        guard let study = try await studyRepository.findWithComponentsAndSchedules(id: studyId) else {
            throw ServerError.notFound(resource: "Study", identifier: studyId.uuidString)
        }
        return try preparePublication(from: study, revision: revision)
    }

    /// The caller captures and authorizes the entire draft before invoking this builder.
    /// No database, authorization or external resource lookup occurs while building.
    func preparePublication(from study: Study, revision: Int) throws -> Publication {
        guard revision > 0 else { throw ServerError.badRequest("Study revision must be positive") }
        let studyId = try study.requireId()
        guard let capturedComponents = study.$components.value,
              capturedComponents.allSatisfy({ $0.$schedules.value != nil }) else {
            throw ServerError.internalServerError("Study draft snapshot is incomplete")
        }
        guard capturedComponents.count <= 256 else { throw Self.resourceLimitExceeded }
        let collectionPolicy = try PublishedCollectionPolicy.compile(studyID: studyId, revision: revision, requirements: study.collectionRequirements)

        var consentMarkdown = LocalizationsDictionary<String>()
        for (locale, content) in study.consent {
            let markdown = ConsentPresentation.markdown(content: content)
            do {
                _ = try ConsentResponseRequirements(markdown: markdown)
            } catch {
                throw ServerError.badRequest("Consent contains invalid or unsupported response controls")
            }
            consentMarkdown[locale] = markdown
        }
        try checkResources(consent: consentMarkdown, components: capturedComponents)

        let (metadata, consentFiles) = try buildMetadata(from: study, consentMarkdown: consentMarkdown)
        let components = try buildComponents(from: capturedComponents)
        let schedules = capturedComponents.flatMap { $0.schedules.map(\.scheduleData) }

        let definition = StudyDefinition(
            studyRevision: UInt(revision),
            metadata: metadata,
            components: components.definitions,
            componentSchedules: schedules
        )
        let archive = try writeBundleZip(
            studyId: studyId, definition: definition, files: consentFiles + components.files, collectionPolicy: collectionPolicy
        )
        let questionnaires = try archivedQuestionnaires(in: archive, inputs: components.questionnaires)

        return Publication(
            metadata: metadata,
            consent: consentMarkdown,
            visibility: study.visibility,
            enrollmentCondition: study.enrollmentCondition,
            collectionPolicy: collectionPolicy,
            groupID: study.$group.id,
            bundle: archive,
            questionnaires: questionnaires
        )
    }
}


extension StudyBundleService {
    /// Grove merges translations during bundle construction. Only the resulting archive
    /// bytes may receive validation evidence; validating the inputs would attest different content.
    private func archivedQuestionnaires(in bytes: Data, inputs: [QuestionnaireResource]) throws -> [QuestionnaireResource] {
        let archive = try Archive(data: bytes, accessMode: .read)
        let entries = archive.filter { $0.path.contains("/questionnaire/") && $0.type == .file }
        let components = Dictionary(grouping: inputs, by: \.componentID)
        guard entries.count == components.count else { throw Self.missingResource }
        return try components.keys.sorted(by: { $0.uuidString < $1.uuidString }).map { id in
            let candidates = (components[id] ?? []).compactMap { input -> (QuestionnaireResource, Entry)? in
                let suffix = "/questionnaire/\(id.uuidString.lowercased())+\(input.locale).json"
                guard let entry = entries.first(where: { $0.path.hasSuffix(suffix) }) else {
                    return nil
                }
                return (input, entry)
            }
            guard candidates.count == 1, let (input, entry) = candidates.first else { throw Self.missingResource }
            var content = Data()
            _ = try archive.extract(entry) { chunk in
                guard chunk.count <= ArtifactReference.Purpose.publication.maximumBytes - content.count else {
                    throw Self.resourceLimitExceeded
                }
                content.append(chunk)
            }
            return QuestionnaireResource(componentID: id, locale: input.locale, bytes: content)
        }
    }
}


extension StudyBundleService {
    private struct ComponentResources {
        var definitions: [StudyDefinition.Component] = []
        var files: [StudyBundle.FileResourceInput] = []
        var questionnaires: [QuestionnaireResource] = []
    }

    private struct QuestionnaireFiles {
        let definition: StudyDefinition.Component
        let files: [StudyBundle.FileResourceInput]
        let resources: [QuestionnaireResource]
    }

    // MARK: - Metadata

    private func buildMetadata(
        from study: Study,
        consentMarkdown: LocalizationsDictionary<String>
    ) throws -> (StudyDefinition.Metadata, [StudyBundle.FileResourceInput]) {
        var titles = LocalizationsDictionary<String>()
        var shortTitles = LocalizationsDictionary<String>()
        var explanationTexts = LocalizationsDictionary<String>()
        var shortExplanationTexts = LocalizationsDictionary<String>()

        for (locale, content) in study.details {
            titles[locale] = content.title
            shortTitles[locale] = content.shortTitle
            explanationTexts[locale] = content.explanationText
            shortExplanationTexts[locale] = content.shortExplanationText
        }

        let (consentRef, consentFiles) = try buildConsentFiles(from: consentMarkdown)

        let metadata = StudyDefinition.Metadata(
            id: try study.requireId(),
            title: titles,
            shortTitle: shortTitles,
            icon: .none,
            explanationText: explanationTexts,
            shortExplanationText: shortExplanationTexts,
            participationCriterion: study.participationCriterion,
            consentFileRef: consentRef
        )

        return (metadata, consentFiles)
    }

    private func buildConsentFiles(
        from consent: LocalizationsDictionary<String>
    ) throws -> (StudyBundle.FileReference?, [StudyBundle.FileResourceInput]) {
        guard !consent.isEmpty else {
            return (nil, [])
        }

        let ref = StudyBundle.FileReference(category: .consent, filename: "Consent", fileExtension: "md")
        let files = try consent.map { locale, markdown in
            try StudyBundle.FileResourceInput(fileRef: ref, localization: locale, contents: markdown)
        }
        return (ref, files)
    }

    // MARK: - Components

    private func buildComponents(
        from components: [Component]
    ) throws -> ComponentResources {
        var result = ComponentResources()

        for component in components {
            let componentId = try component.requireId()

            switch component.data {
            case .informational(let content):
                let (definition, componentFiles) = try buildInformational(
                    id: componentId,
                    content: content
                )
                result.definitions.append(definition)
                result.files += componentFiles

            case .questionnaire(let content):
                let questionnaire = buildQuestionnaire(
                    id: componentId,
                    content: content
                )
                result.definitions.append(questionnaire.definition)
                result.files += questionnaire.files
                result.questionnaires += questionnaire.resources

            case .healthDataCollection(let data):
                result.definitions.append(.healthDataCollection(data))
            }
        }

        return result
    }

    private func buildInformational(
        id: UUID,
        content: LocalizationsDictionary<InformationalContent>
    ) throws -> (StudyDefinition.Component, [StudyBundle.FileResourceInput]) {
        let fileRef = StudyBundle.FileReference(category: .informationalArticle, filename: id.uuidString.lowercased(), fileExtension: "md")
        let definition = StudyDefinition.Component.informational(.init(id: id, fileRef: fileRef))

        let files = try content.map { locale, item in
            try StudyBundle.FileResourceInput(fileRef: fileRef, localization: locale, contents: informationalMarkdown(id: id, content: item))
        }

        return (definition, files)
    }

    private func buildQuestionnaire(
        id: UUID,
        content: LocalizationsDictionary<QuestionnaireContent>
    ) -> QuestionnaireFiles {
        let fileRef = StudyBundle.FileReference(category: .questionnaire, filename: id.uuidString.lowercased(), fileExtension: "json")
        let definition = StudyDefinition.Component.questionnaire(.init(id: id, fileRef: fileRef))

        var files: [StudyBundle.FileResourceInput] = []
        var resources: [QuestionnaireResource] = []
        for (locale, item) in content {
            let bytes = Data(item.questionnaire.utf8)
            files.append(StudyBundle.FileResourceInput(fileRef: fileRef, localization: locale, contents: bytes))
            resources.append(QuestionnaireResource(componentID: id, locale: locale.description, bytes: bytes))
        }

        return QuestionnaireFiles(definition: definition, files: files, resources: resources)
    }
}


extension StudyBundleService {
    private static var resourceLimitExceeded: ServerError {
        .init(
            status: .contentTooLarge,
            title: "Study Resource Limit Exceeded",
            detail: "A study supports 256 components, 1024 localized files and 50 MiB of resource data"
        )
    }

    private static var missingResource: ServerError {
        .init(status: .unprocessableContent, title: "Invalid Study Bundle", detail: "Each document component must include a localized resource")
    }

    private func informationalMarkdown(id: UUID, content: InformationalContent) -> String {
        var markdown = "---\nid: \(id.uuidString)\ntitle: \(ConsentPresentation.yamlEscape(content.title))\n"
        if let lede = content.lede {
            markdown += "lede: \(ConsentPresentation.yamlEscape(lede))\n"
        }
        return markdown + "---\n\(content.content)"
    }

    /// Bound uncompressed inputs before writing an archive or contacting the validator.
    private func checkResources(consent: LocalizationsDictionary<String>, components: [Component]) throws {
        var paths: Set<String> = []
        var identifiers: Set<UUID> = []
        var remainingBytes = ArtifactReference.Purpose.publication.maximumBytes
        func register(_ category: String, _ filename: String, _ locale: LocalizationKey, _ content: String) throws {
            let key = locale.description
            guard !key.isEmpty, key.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }),
                  paths.insert("\(category)/\(filename)+\(key)".lowercased()).inserted else {
                throw ServerError.badRequest("Study resource locations must be unique and use supported locale identifiers")
            }
            let bytes = content.utf8.count
            guard paths.count <= 1024, bytes <= remainingBytes else { throw Self.resourceLimitExceeded }
            remainingBytes -= bytes
        }
        for (locale, content) in consent {
            try register("consent", "Consent", locale, content)
        }
        for component in components {
            let identifier = try component.requireId()
            guard identifiers.insert(identifier).inserted else { throw ServerError.badRequest("Study component identifiers must be unique") }
            switch component.data {
            case .informational(let content):
                guard !content.isEmpty else { throw Self.missingResource }
                for (locale, item) in content {
                    try register("article", identifier.uuidString, locale, informationalMarkdown(id: identifier, content: item))
                }
            case .questionnaire(let content):
                guard !content.isEmpty else { throw Self.missingResource }
                for (locale, item) in content {
                    try register("questionnaire", identifier.uuidString, locale, item.questionnaire)
                }
            case .healthDataCollection: break
            }
        }
    }

    // MARK: - Bundle Writing

    private func writeBundleZip(
        studyId: UUID,
        definition: StudyDefinition,
        files: [StudyBundle.FileResourceInput],
        collectionPolicy: PublishedCollectionPolicy
    ) throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = tempDir.appendingPathComponent("\(studyId).\(StudyBundle.fileExtension)", isDirectory: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let policyURL = tempDir.appendingPathComponent(PublishedCollectionPolicy.filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(collectionPolicy).write(to: policyURL, options: .atomic)
        let policyFile = StudyBundle.FileResourceInput(pathInBundle: PublishedCollectionPolicy.filename, contentsOf: policyURL)

        let bundle: StudyBundle
        do {
            bundle = try StudyBundle.writeToDisk(at: bundleURL, definition: definition, files: files + [policyFile])
        } catch StudyBundle.CreateBundleError.failedValidation {
            throw ServerError(
                status: .unprocessableContent, title: "Invalid Study Bundle", detail: "Study resources do not satisfy bundle requirements"
            )
        } catch is DecodingError {
            throw ServerError(status: .unprocessableContent, title: "Invalid Study Bundle", detail: "Study resources contain invalid structured data")
        } catch {
            throw ServerError.internalServerError("Failed to build study bundle")
        }
        guard definition.validate(in: bundle) else {
            throw ServerError(
                status: .unprocessableContent,
                title: "Invalid Study Bundle",
                detail: "Study schedules and resources must reference existing components"
            )
        }

        return try zipDirectory(at: bundleURL)
    }

    private func zipDirectory(at directoryURL: URL) throws -> Data {
        let archive = try Archive(accessMode: .create)

        let resolvedDirectory = directoryURL.resolvingSymlinksInPath()
        let baseName = resolvedDirectory.lastPathComponent
        let basePath = resolvedDirectory.path

        guard let enumerator = FileManager.default.enumerator(
            at: resolvedDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            throw ServerError.internalServerError("Failed to enumerate bundle directory")
        }

        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
            let resolvedFile = fileURL.resolvingSymlinksInPath()
            let relativePath = resolvedFile.path.replacingOccurrences(of: basePath + "/", with: "")
            let entryPath = "\(baseName)/\(relativePath)"

            if resourceValues.isDirectory == true {
                try archive.addEntry(
                    with: entryPath + "/",
                    type: .directory,
                    uncompressedSize: Int64(0),
                    provider: { (_: Int64, _: Int) in Data() }
                )
            } else {
                let fileData = try Data(contentsOf: fileURL)
                try archive.addEntry(
                    with: entryPath,
                    type: .file,
                    uncompressedSize: Int64(fileData.count),
                    compressionMethod: .deflate,
                    provider: { (position: Int64, size: Int) in
                        fileData[Int(position)..<(Int(position) + size)]
                    }
                )
            }
        }

        guard let data = archive.data else {
            throw ServerError.internalServerError("Failed to create ZIP archive")
        }

        return data
    }
}
