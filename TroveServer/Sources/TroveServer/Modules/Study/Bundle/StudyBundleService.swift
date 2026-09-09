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
import GroveStudyDefinition
import TroveAPIServer
import ZIPFoundation


final class StudyBundleService: Module, @unchecked Sendable {
    struct Publication: Sendable {
        let metadata: StudyDefinition.Metadata
        let consent: LocalizationsDictionary<String>
        let visibility: StudyVisibility
        let enrollmentCondition: EnrollmentConditions
        let collectionPolicy: PublishedCollectionPolicy
        let groupID: UUID
        let bundle: Data
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

        let (metadata, consentFiles) = try await buildMetadata(from: study, consentMarkdown: consentMarkdown)
        let (components, componentFiles) = try buildComponents(from: study.components)
        let schedules = study.components.flatMap { $0.schedules.map(\.scheduleData) }

        let definition = StudyDefinition(
            studyRevision: UInt(revision),
            metadata: metadata,
            components: components,
            componentSchedules: schedules
        )

        return Publication(
            metadata: metadata,
            consent: consentMarkdown,
            visibility: study.visibility,
            enrollmentCondition: study.enrollmentCondition,
            collectionPolicy: collectionPolicy,
            groupID: study.$group.id,
            bundle: try writeBundleZip(
                studyId: studyId, definition: definition, files: consentFiles + componentFiles, collectionPolicy: collectionPolicy
            )
        )
    }

    // MARK: - Metadata

    private func buildMetadata(
        from study: Study,
        consentMarkdown: LocalizationsDictionary<String>
    ) async throws -> (StudyDefinition.Metadata, [StudyBundle.FileResourceInput]) {
        try await authorizationService.checkResearcherHasStudyAccess(study.requireId(), role: .researcher)
        
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
    ) throws -> ([StudyDefinition.Component], [StudyBundle.FileResourceInput]) {
        var definitions: [StudyDefinition.Component] = []
        var files: [StudyBundle.FileResourceInput] = []

        for component in components {
            let componentId = try component.requireId()

            switch component.data {
            case .informational(let content):
                let (definition, componentFiles) = try buildInformational(
                    id: componentId,
                    name: component.name,
                    content: content
                )
                definitions.append(definition)
                files += componentFiles

            case .questionnaire(let content):
                let (definition, componentFiles) = try buildQuestionnaire(
                    id: componentId,
                    name: component.name,
                    content: content
                )
                definitions.append(definition)
                files += componentFiles

            case .healthDataCollection(let data):
                definitions.append(.healthDataCollection(data))
            }
        }

        return (definitions, files)
    }

    private func buildInformational(
        id: UUID,
        name: String,
        content: LocalizationsDictionary<InformationalContent>
    ) throws -> (StudyDefinition.Component, [StudyBundle.FileResourceInput]) {
        let fileRef = StudyBundle.FileReference(category: .informationalArticle, filename: name, fileExtension: "md")
        let definition = StudyDefinition.Component.informational(.init(id: id, fileRef: fileRef))

        let files = try content.map { locale, item in
            var markdown = "---\nid: \(id.uuidString)\ntitle: \(ConsentPresentation.yamlEscape(item.title))\n"
            if let lede = item.lede {
                markdown += "lede: \(ConsentPresentation.yamlEscape(lede))\n"
            }
            markdown += "---\n\(item.content)"
            return try StudyBundle.FileResourceInput(fileRef: fileRef, localization: locale, contents: markdown)
        }

        return (definition, files)
    }

    private func buildQuestionnaire(
        id: UUID,
        name: String,
        content: LocalizationsDictionary<QuestionnaireContent>
    ) throws -> (StudyDefinition.Component, [StudyBundle.FileResourceInput]) {
        let fileRef = StudyBundle.FileReference(category: .questionnaire, filename: name, fileExtension: "json")
        let definition = StudyDefinition.Component.questionnaire(.init(id: id, fileRef: fileRef))

        let files = content.map { locale, item in
            StudyBundle.FileResourceInput(fileRef: fileRef, localization: locale, contents: Data(item.questionnaire.utf8))
        }

        return (definition, files)
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

        do {
            _ = try StudyBundle.writeToDisk(at: bundleURL, definition: definition, files: files + [policyFile])
        } catch {
            throw ServerError.internalServerError("Failed to build study bundle: \(error)")
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
