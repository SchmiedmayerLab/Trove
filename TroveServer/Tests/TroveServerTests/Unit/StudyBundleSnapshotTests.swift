//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import GroveLocalization
import Testing
import TroveAPIServer
@testable import TroveServer
import ZIPFoundation


struct StudyBundleSnapshotTests {
    enum ResourceLimit: CaseIterable {
        case components, localizations, bytes
    }

    @Test("Duplicate editable names cannot overwrite questionnaire resources")
    func duplicateNames() throws {
        let study = try Self.study()
        let studyID = try study.requireId()
        let first = Self.questionnaire(studyID: studyID, id: UUID())
        let second = Self.questionnaire(studyID: studyID, id: UUID())
        study.$components.value = [first, second]

        let publication = try StudyBundleService().preparePublication(from: study, revision: 1)
        #expect(publication.questionnaires.count == 2)
        #expect(Set(publication.questionnaires.map(\.componentID)).count == 2)
        try Self.verifyArchive(publication)
    }

    @Test("Validation receives each multilingual questionnaire as stored, with its languages")
    func multilingualResources() throws {
        let study = try Self.study()
        let fixtures = try MultilingualQuestionnaireFixture.all()
        study.$components.value = try fixtures.map { fixture in
            let component = Self.questionnaire(studyID: try study.requireId(), id: UUID())
            component.data = .questionnaire(try fixture.content())
            return component
        }

        let publication = try StudyBundleService().preparePublication(from: study, revision: 1)
        #expect(publication.questionnaires.count == fixtures.count)
        for fixture in fixtures {
            let resource = try #require(publication.questionnaires.first { $0.bytes == (try? fixture.bytes()) })
            #expect(resource.language == fixture.language)
        }
        try Self.verifyArchive(publication)
    }

    @Test("A base language without a region fails before archive writing", arguments: ["de", "zh-Hant", "Weekly"])
    func baseLanguageWithoutRegion(language: String) throws {
        let study = try Self.study()
        let component = Self.questionnaire(studyID: try study.requireId(), id: UUID(), language: language)
        study.$components.value = [component]
        do {
            _ = try StudyBundleService().preparePublication(from: study, revision: 1)
            Issue.record("The participant bundle cannot name this base language")
        } catch let error as ServerError {
            #expect(error.status == .unprocessableContent)
            #expect(error.detail.contains("Questionnaire.language"))
        }
    }

    @Test("Study details languages map to distinct participant bundle locales")
    func detailLanguages() throws {
        let expected = ["en": "en-US", "de": "de-DE", "zh-Hant": "zh-TW", "pt-BR": "pt-BR", "ar": "ar-EG", "es-419": "es-419"]
        var content: [LanguageTag: StudyDetailContent] = [:]
        for language in expected.keys {
            content[try #require(LanguageTag(rawValue: language))] = StudyDetailContent(title: "Title \(language)")
        }
        let study = try Self.study()
        let english = try #require(LanguageTag(rawValue: "en"))
        study.details = try #require(StudyDetailData(sourceLanguage: english, content: content))
        study.$components.value = []

        let metadata = try StudyBundleService().preparePublication(from: study, revision: 1).metadata
        #expect(metadata.title.count == expected.count)
        for (language, locale) in expected {
            #expect(metadata.title[try #require(LocalizationKey(locale))] == "Title \(language)")
        }
    }

    @Test("Study details languages that share or lack a participant bundle locale fail", arguments: [["de", "de-DE"], ["sr-Latn"]])
    func conflictingDetailLanguages(languages: [String]) throws {
        let tags = try languages.map { try #require(LanguageTag(rawValue: $0)) }
        let study = try Self.study()
        study.details = try #require(StudyDetailData(
            sourceLanguage: tags[0],
            content: Dictionary(uniqueKeysWithValues: tags.map { ($0, StudyDetailContent(title: $0.rawValue)) })
        ))
        study.$components.value = []
        #expect {
            try StudyBundleService().preparePublication(from: study, revision: 1)
        } throws: { error in
            guard let error = error as? ServerError else {
                return false
            }
            return error.status == .unprocessableContent && languages.allSatisfy { error.detail.contains($0) }
        }
    }

    @Test("Archived questionnaire bytes that differ from the stored resource receive no evidence")
    func rewrittenArchiveIsRejected() throws {
        let study = try Self.study()
        let componentID = UUID()
        study.$components.value = [Self.questionnaire(studyID: try study.requireId(), id: componentID)]
        let publication = try StudyBundleService().preparePublication(from: study, revision: 1)
        let stored = try #require(publication.questionnaires.first)
        let changed = StudyBundleService.QuestionnaireResource(
            componentID: componentID, bytes: stored.bytes + Data(" ".utf8), language: stored.language
        )
        #expect(try StudyBundleService.archivedQuestionnaires(in: publication.bundle, inputs: [stored]).first?.bytes == stored.bytes)
        #expect {
            try StudyBundleService.archivedQuestionnaires(in: publication.bundle, inputs: [changed])
        } throws: { ($0 as? ServerError)?.status == .internalServerError }
    }

    @Test("Duplicate component identities fail before resource writing")
    func duplicateIdentities() throws {
        let study = try Self.study()
        let component = Self.questionnaire(studyID: try study.requireId(), id: UUID())
        study.$components.value = [component, component]
        #expect(throws: ServerError.self) {
            try StudyBundleService().preparePublication(from: study, revision: 1)
        }
    }

    @Test("A partially loaded snapshot fails without dereferencing unloaded relationships")
    func incompleteSnapshot() throws {
        let study = try Self.study()
        let component = Self.questionnaire(studyID: try study.requireId(), id: UUID())
        component.$schedules.value = nil
        study.$components.value = [component]
        #expect(throws: ServerError.self) {
            try StudyBundleService().preparePublication(from: study, revision: 1)
        }
    }

    @Test("Invalid questionnaire input returns a bounded validation error without authored content", arguments: [true, false])
    func invalidResource(isMalformed: Bool) throws {
        let study = try Self.study()
        let component = Self.questionnaire(studyID: try study.requireId(), id: UUID())
        let marker = "synthetic-private-content"
        let invalid = """
            {"resourceType":"Questionnaire","id":"synthetic","status":"active","language":"\(marker)"}
            """
        component.data = .questionnaire(QuestionnaireContent(questionnaire: isMalformed ? marker : invalid))
        study.$components.value = [component]
        do {
            _ = try StudyBundleService().preparePublication(from: study, revision: 1)
            Issue.record("Invalid resource was accepted")
        } catch let error as ServerError {
            #expect(error.status == .unprocessableContent)
            #expect(!error.detail.contains(marker))
        }
    }

    @Test("Empty document resources fail before upstream bundle validation", arguments: [true, false])
    func emptyResources(isQuestionnaire: Bool) throws {
        let study = try Self.study()
        let component = Self.questionnaire(studyID: try study.requireId(), id: UUID())
        component.data = isQuestionnaire ? .questionnaire(QuestionnaireContent(questionnaire: "")) : .informational(.init())
        study.$components.value = [component]
        do {
            _ = try StudyBundleService().preparePublication(from: study, revision: 1)
            Issue.record("Missing referenced resources were accepted")
        } catch let error as ServerError {
            #expect(error.status == .unprocessableContent)
        }
    }

    @Test("Schedule references and identities must close over the captured components", arguments: [true, false])
    func invalidSchedules(hasMissingTarget: Bool) throws {
        let study = try Self.study()
        let componentID = UUID()
        let component = Self.questionnaire(studyID: try study.requireId(), id: componentID)
        let schedule = ComponentSchedule(componentId: componentID, scheduleData: .init(
            id: UUID(),
            componentId: hasMissingTarget ? UUID() : componentID,
            scheduleDefinition: .repeated(.daily(interval: 1, hour: 9, minute: 0, second: 0), offset: DateComponents()),
            completionPolicy: .anytime,
            notifications: .disabled
        ))
        component.$schedules.value = hasMissingTarget ? [schedule] : [schedule, schedule]
        study.$components.value = [component]
        do {
            _ = try StudyBundleService().preparePublication(from: study, revision: 1)
            Issue.record("Unclosed or ambiguous schedule references were accepted")
        } catch let error as ServerError {
            #expect(error.status == .unprocessableContent)
        }
    }

    @Test("Oversized study resources fail before archive writing", arguments: ResourceLimit.allCases)
    func resourceLimits(limit: ResourceLimit) throws {
        let study = try Self.study()
        let studyID = try study.requireId()
        switch limit {
        case .components:
            study.$components.value = (0..<257).map { _ in Self.questionnaire(studyID: studyID, id: UUID()) }
        case .localizations:
            var articles = LocalizationsDictionary<InformationalContent>()
            for locale in ["en-US", "de-DE", "en-GB", "fr-FR", "es-ES"] {
                articles[try #require(LocalizationKey(locale))] = InformationalContent(title: "Synthetic", content: "Synthetic")
            }
            study.$components.value = (0..<205).map { _ in
                let component = Component(studyId: studyID, data: .informational(articles), name: "Synthetic Article", id: UUID())
                component.$schedules.value = []
                return component
            }
        case .bytes:
            let component = Self.questionnaire(studyID: studyID, id: UUID())
            let oversized = String(repeating: "x", count: ArtifactReference.Purpose.publication.maximumBytes + 1)
            component.data = .questionnaire(QuestionnaireContent(questionnaire: oversized))
            study.$components.value = [component]
        }
        do {
            _ = try StudyBundleService().preparePublication(from: study, revision: 1)
            Issue.record("Study resource limit was not enforced")
        } catch let error as ServerError {
            #expect(error.status == .contentTooLarge)
        }
    }
}


extension StudyBundleSnapshotTests {
    private static func study() throws -> Study {
        Study(
            groupId: UUID(),
            locales: [.enUS],
            icon: "heart",
            details: StudyDetailData(sourceLanguage: try #require(LanguageTag(rawValue: "en")), source: StudyDetailContent(title: "Synthetic Study")),
            id: UUID()
        )
    }

    private static func questionnaire(studyID: UUID, id: UUID, language: String = "en-US") -> Component {
        let content = QuestionnaireContent(questionnaire: """
            {
              "resourceType": "Questionnaire", "id": "\(id)", "status": "active",
              "language": "\(language)", "title": "Synthetic",
              "item": [{"linkId": "answer", "type": "integer", "text": "Synthetic"}]
            }
            """)
        let component = Component(studyId: studyID, data: .questionnaire(content), name: "../Shared Name", id: id)
        component.$schedules.value = []
        return component
    }

    private static func verifyArchive(_ publication: StudyBundleService.Publication) throws {
        let archive = try Archive(data: publication.bundle, accessMode: .read)
        let questionnaireEntries = archive.filter { $0.path.contains("/questionnaire/") && $0.type == .file }
        #expect(questionnaireEntries.count == publication.questionnaires.count)
        for resource in publication.questionnaires {
            let filename = "\(resource.componentID.uuidString.lowercased())+\(resource.language).json"
            let entry = try #require(questionnaireEntries.first { $0.path.hasSuffix("/" + filename) })
            var bytes = Data()
            _ = try archive.extract(entry) { bytes.append($0) }
            #expect(bytes == resource.bytes)
        }
    }
}
