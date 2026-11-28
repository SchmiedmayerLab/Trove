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
    /// One multilingual Questionnaire and the base language that names its archived file.
    struct QuestionnaireResource: Sendable {
        let componentID: UUID
        let bytes: Data
        let language: String
    }

    struct Publication: Sendable {
        let metadata: StudyDefinition.Metadata
        let consent: LocalizationsDictionary<String>
        let visibility: StudyVisibility
        let enrollmentCondition: EnrollmentConditions
        let collectionPolicy: PublishedCollectionPolicy
        let groupID: UUID
        let bundle: Data
        let taskSchedules: [StudyDefinition.ComponentSchedule]
        let questionnaires: [QuestionnaireResource]
    }

    /// The deployment's stable HTTP(S) namespace for published study definitions.
    let canonicalBase: String?
    @Dependency(AuthorizationService.self) var authorizationService
    @Dependency(StudyRepository.self) var studyRepository

    init(canonicalBase: String? = nil) throws { self.canonicalBase = try Self.definitionNamespace(canonicalBase) }

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
    /// `unavailable` names the optional requirements whose route is unavailable; the policy grants none of them.
    func preparePublication(from study: Study, revision: Int, unavailable: [CollectionRequirement] = []) throws -> Publication {
        guard revision > 0 else { throw ServerError.badRequest("Study revision must be positive") }
        let studyId = try study.requireId()
        guard let capturedComponents = study.$components.value,
              capturedComponents.allSatisfy({ $0.$schedules.value != nil }) else {
            throw ServerError.internalServerError("Study draft snapshot is incomplete")
        }

        let collectionPolicy = try PublishedCollectionPolicy.compile(
            studyID: studyId,
            revision: revision,
            requirements: study.collectionRequirements.filter { !unavailable.contains($0) },
            receivesDeviceUnitIdentifiers: study.receivesDeviceUnitIdentifiers,
            enrollmentPeriod: study.enrollmentPeriod,
            unavailableRequirements: unavailable
        )

        let consentMarkdown = try Self.consentMarkdown(for: study, collectionPolicy: collectionPolicy)
        try checkResources(consent: consentMarkdown, components: capturedComponents)

        let (metadata, consentFiles) = try buildMetadata(from: study, consentMarkdown: consentMarkdown)
        let components = try buildComponents(from: capturedComponents)
        let schedules = try Self.validatedSchedules(capturedComponents, timeZone: collectionPolicy.enrollmentPeriod.timeZone)

        let definition = StudyDefinition(
            studyRevision: UInt(revision),
            metadata: metadata,
            components: components.definitions,
            componentSchedules: schedules
        )
        let tasks = try taskDefinitions(study: studyId, revision: revision, schedules: schedules, inputs: components.questionnaires)
        let archive = try writeBundleZip(
            studyId: studyId,
            definition: definition,
            files: consentFiles + components.files,
            collectionPolicy: collectionPolicy,
            taskDefinitions: tasks.graph
        )
        guard !tasks.unconfigured else { throw Self.missingDefinitionNamespace }
        let questionnaires = try Self.archivedQuestionnaires(in: archive, inputs: components.questionnaires)

        return Publication(
            metadata: metadata,
            consent: consentMarkdown,
            visibility: study.visibility,
            enrollmentCondition: study.enrollmentCondition,
            collectionPolicy: collectionPolicy,
            groupID: study.$group.id,
            bundle: archive,
            taskSchedules: schedules,
            questionnaires: questionnaires
        )
    }
}


extension StudyBundleService {
    private static func validatedSchedules(_ components: [Component], timeZone: String) throws -> [StudyDefinition.ComponentSchedule] {
        let calendar = try PublishedTaskPlan.calendar(timeZone: timeZone)
        return try components.flatMap { component in
            try component.schedules.map { schedule in
                // Older drafts stored a separate UUID in the serialized schedule.
                var data = schedule.scheduleData
                data.id = try schedule.requireId()
                try PublishedTaskSchedule.validate(data.scheduleDefinition, scheduleID: data.id, calendar: calendar)
                return data
            }
        }
    }

    /// Only archive bytes may receive validation evidence. Each component's one resource
    /// must be archived exactly as stored; a rewritten resource would attest different content.
    static func archivedQuestionnaires(in bytes: Data, inputs: [QuestionnaireResource]) throws -> [QuestionnaireResource] {
        let archive = try Archive(data: bytes, accessMode: .read)
        let entries = archive.filter { $0.path.contains("/questionnaire/") && $0.type == .file }
        guard entries.count == inputs.count else { throw Self.missingResource }
        var remainingBytes = ArtifactReference.Purpose.publication.maximumBytes
        return try inputs.sorted(by: { $0.componentID.uuidString < $1.componentID.uuidString }).map { input in
            let prefix = "/questionnaire/\(input.componentID.uuidString.lowercased())+"
            let matches = entries.filter { $0.path.contains(prefix) }
            guard matches.count == 1, let entry = matches.first else { throw Self.missingResource }
            var content = Data()
            _ = try archive.extract(entry) { chunk in
                guard chunk.count <= remainingBytes else {
                    throw Self.resourceLimitExceeded
                }
                remainingBytes -= chunk.count
                content.append(chunk)
            }
            guard content == input.bytes else { throw ServerError.internalServerError("The study bundle changed a Questionnaire") }
            return input
        }
    }

    /// The consent of each locale with the collection scope and enrollment period the policy grants.
    private static func consentMarkdown(
        for study: Study,
        collectionPolicy: PublishedCollectionPolicy
    ) throws -> LocalizationsDictionary<String> {
        var consentMarkdown = LocalizationsDictionary<String>()
        for (locale, content) in study.consent {
            let markdown = ConsentPresentation.markdown(content: content)
                + (try CollectionScopePresentation.markdown(requirements: collectionPolicy.requirements, locale: locale.description))
                + (try EnrollmentPeriodPresentation.markdown(collectionPolicy.enrollmentPeriod, locale: locale.description))
            do {
                _ = try ConsentResponseRequirements(markdown: markdown)
            } catch {
                throw ServerError.badRequest("Consent contains invalid or unsupported response controls")
            }
            consentMarkdown[locale] = markdown
        }
        return consentMarkdown
    }
}


extension StudyBundleService {
    private struct ComponentResources {
        var definitions: [StudyDefinition.Component] = []
        var files: [StudyBundle.FileResourceInput] = []
        var questionnaires: [QuestionnaireResource] = []
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

        var languages: [LocalizationKey: LanguageTag] = [:]
        for (language, content) in study.details.content.sorted(by: { $0.key < $1.key }) {
            guard let locale = Self.bundleLocalization(for: language) else {
                throw Self.unsupportedDetailLanguage("\(language) has no language and region")
            }
            if let other = languages.updateValue(language, forKey: locale) {
                throw Self.unsupportedDetailLanguage("\(other) and \(language) share \(locale)")
            }
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
                try addQuestionnaire(id: componentId, content: content, to: &result)

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

    /// The component's one multilingual resource, archived as one file without rewriting.
    private func addQuestionnaire(id: UUID, content: QuestionnaireContent, to result: inout ComponentResources) throws {
        let fileRef = StudyBundle.FileReference(category: .questionnaire, filename: id.uuidString.lowercased(), fileExtension: "json")
        let bytes = Data(content.questionnaire.utf8)
        // The pinned Grove bundle names the file by the base language and requires it to have a region.
        guard let language = QuestionnaireLanguages(bytes).base, let localization = LocalizationKey(language) else {
            throw Self.unsupportedQuestionnaireLanguage
        }
        result.definitions.append(.questionnaire(.init(id: id, fileRef: fileRef)))
        result.files.append(StudyBundle.FileResourceInput(fileRef: fileRef, localization: localization, contents: bytes))
        result.questionnaires.append(QuestionnaireResource(componentID: id, bytes: bytes, language: language))
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

    private static var unsupportedQuestionnaireLanguage: ServerError {
        .init(
            status: .unprocessableContent,
            title: "Invalid Study Bundle",
            detail: "Questionnaire.language must name a language and region, for example en-US, to publish the resource"
        )
    }

    /// Language tags are validated identifiers, not authored text, so the detail can name them.
    private static func unsupportedDetailLanguage(_ reason: String) -> ServerError {
        .init(
            status: .unprocessableContent,
            title: "Invalid Study Bundle",
            detail: "Each study details language must map to a distinct language and region in the participant bundle: \(reason)"
        )
    }

    /// Study details languages that the participant bundle cannot key, as publication blockers.
    static func detailLanguageDiagnostics(_ languages: some Sequence<LanguageTag>) -> [ValidationDiagnostic] {
        var keys: [LocalizationKey: LanguageTag] = [:]
        var diagnostics: [ValidationDiagnostic] = []
        for language in languages.sorted() {
            let path = "details.content.\(language)"
            guard let locale = bundleLocalization(for: language) else {
                diagnostics.append(.trove(
                    "details-language-region",
                    path: path,
                    message: "The participant bundle cannot key \(language) by a language and region.",
                    nextAction: "Use a tag with a region, for example sr-Latn-RS."
                ))
                continue
            }
            if let other = keys.updateValue(language, forKey: locale) {
                diagnostics.append(.trove(
                    "details-language-distinct",
                    path: path,
                    message: "\(other) and \(language) share the participant bundle key \(locale).",
                    nextAction: "Keep the study details in only one of these languages."
                ))
            }
        }
        return diagnostics
    }

    /// The participant bundle keys study details by language and region.
    ///
    /// A tag without a region takes its likely region (`de` as `de-DE`, `zh-Hant` as `zh-TW`), and the key must name
    /// the same language and script as the tag. A tag that no key represents (`sr-Latn`) cannot be published.
    static func bundleLocalization(for tag: LanguageTag) -> LocalizationKey? {
        let language = Locale.Language(identifier: tag.rawValue)
        guard let code = language.languageCode?.identifier,
              let region = language.region ?? Locale.Language(identifier: language.maximalIdentifier).region else {
            return nil
        }
        let identifier = "\(code)-\(region.identifier)"
        guard Locale.Language(identifier: identifier).maximalIdentifier == language.maximalIdentifier else {
            return nil
        }
        return LocalizationKey(identifier)
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
        guard components.count <= 256 else { throw Self.resourceLimitExceeded }
        var paths: Set<String> = []
        var identifiers: Set<UUID> = []
        var remainingBytes = ArtifactReference.Purpose.publication.maximumBytes
        func register(_ category: String, _ filename: String, _ locale: LocalizationKey?, _ content: String) throws {
            let key = locale?.description ?? ""
            guard key.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }),
                  locale == nil || !key.isEmpty,
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
                try register("questionnaire", identifier.uuidString, nil, content.questionnaire)
            case .healthDataCollection: break
            }
        }
    }
}
