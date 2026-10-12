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
        let study = Self.study()
        let studyID = try study.requireId()
        let first = Self.questionnaire(studyID: studyID, id: UUID())
        let second = Self.questionnaire(studyID: studyID, id: UUID())
        study.$components.value = [first, second]

        let publication = try StudyBundleService().preparePublication(from: study, revision: 1)
        #expect(publication.questionnaires.count == 2)
        #expect(Set(publication.questionnaires.map(\.componentID)).count == 2)
        try Self.verifyArchive(publication)
    }

    @Test("Validation receives the exact merged multilingual questionnaire from the archive")
    func localizedResources() throws {
        let german = try #require(LocalizationKey("de-DE"))
        let study = Self.study()
        let component = Self.questionnaire(studyID: try study.requireId(), id: UUID(), locales: [.enUS, german])
        study.$components.value = [component]

        let publication = try StudyBundleService().preparePublication(from: study, revision: 1)
        #expect(publication.questionnaires.count == 1)
        let resource = try #require(publication.questionnaires.first)
        #expect(resource.locale == "en-US")
        let json = try #require(JSONSerialization.jsonObject(with: resource.bytes) as? [String: Any])
        #expect(json["language"] as? String == "en-US")
        let text = String(decoding: try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes]), as: UTF8.self)
        #expect(text.contains("http://hl7.org/fhir/StructureDefinition/translation"))
        #expect(text.contains("Synthetic de-DE"))
        #expect(text.contains("Synthetic en-US"))
        try Self.verifyArchive(publication)
    }

    @Test("Duplicate component identities fail before resource writing")
    func duplicateIdentities() throws {
        let study = Self.study()
        let component = Self.questionnaire(studyID: try study.requireId(), id: UUID())
        study.$components.value = [component, component]
        #expect(throws: ServerError.self) {
            try StudyBundleService().preparePublication(from: study, revision: 1)
        }
    }

    @Test("A partially loaded snapshot fails without dereferencing unloaded relationships")
    func incompleteSnapshot() throws {
        let study = Self.study()
        let component = Self.questionnaire(studyID: try study.requireId(), id: UUID())
        component.$schedules.value = nil
        study.$components.value = [component]
        #expect(throws: ServerError.self) {
            try StudyBundleService().preparePublication(from: study, revision: 1)
        }
    }

    @Test("Invalid questionnaire input returns a bounded validation error without authored content", arguments: [true, false])
    func invalidResource(isMalformed: Bool) throws {
        let study = Self.study()
        let component = Self.questionnaire(studyID: try study.requireId(), id: UUID())
        let marker = "synthetic-private-content"
        let invalid = """
            {"resourceType":"Questionnaire","id":"synthetic","status":"active","language":"\(marker)"}
            """
        component.data = .questionnaire(.init([.enUS: QuestionnaireContent(questionnaire: isMalformed ? marker : invalid)]))
        study.$components.value = [component]
        do {
            _ = try StudyBundleService().preparePublication(from: study, revision: 1)
            Issue.record("Invalid resource was accepted")
        } catch let error as ServerError {
            #expect(error.status == .unprocessableContent)
            #expect(!error.detail.contains(marker))
        }
    }

    @Test("Empty localized document resources fail before upstream bundle validation", arguments: [true, false])
    func emptyResources(isQuestionnaire: Bool) throws {
        let study = Self.study()
        let component = Self.questionnaire(studyID: try study.requireId(), id: UUID())
        component.data = isQuestionnaire ? .questionnaire(.init()) : .informational(.init())
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
        let study = Self.study()
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
        let study = Self.study()
        let studyID = try study.requireId()
        switch limit {
        case .components:
            study.$components.value = (0..<257).map { _ in Self.questionnaire(studyID: studyID, id: UUID()) }
        case .localizations:
            let locales = try ["en-US", "de-DE", "en-GB", "fr-FR", "es-ES"].map { try #require(LocalizationKey($0)) }
            study.$components.value = (0..<205).map { _ in Self.questionnaire(studyID: studyID, id: UUID(), locales: locales) }
        case .bytes:
            let component = Self.questionnaire(studyID: studyID, id: UUID())
            let oversized = String(repeating: "x", count: ArtifactReference.Purpose.publication.maximumBytes + 1)
            component.data = .questionnaire(.init([.enUS: QuestionnaireContent(questionnaire: oversized)]))
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
    private static func study() -> Study {
        Study(
            groupId: UUID(),
            locales: [.enUS],
            icon: "heart",
            details: .init([.enUS: StudyDetailContent(title: "Synthetic Study")]),
            id: UUID()
        )
    }

    private static func questionnaire(studyID: UUID, id: UUID, locales: [LocalizationKey] = [.enUS]) -> Component {
        var content = LocalizationsDictionary<QuestionnaireContent>()
        for locale in locales {
            content[locale] = QuestionnaireContent(questionnaire: """
                {
                  "resourceType": "Questionnaire", "id": "\(id)", "status": "active",
                  "language": "\(locale)", "title": "Synthetic \(locale)",
                  "item": [{"linkId": "answer", "type": "integer", "text": "Synthetic \(locale)"}]
                }
                """)
        }
        let component = Component(studyId: studyID, data: .questionnaire(content), name: "../Shared Name", id: id)
        component.$schedules.value = []
        return component
    }

    private static func verifyArchive(_ publication: StudyBundleService.Publication) throws {
        let archive = try Archive(data: publication.bundle, accessMode: .read)
        let questionnaireEntries = archive.filter { $0.path.contains("/questionnaire/") && $0.type == .file }
        #expect(questionnaireEntries.count == publication.questionnaires.count)
        for resource in publication.questionnaires {
            let filename = "\(resource.componentID.uuidString.lowercased())+\(resource.locale).json"
            let entry = try #require(questionnaireEntries.first { $0.path.hasSuffix("/" + filename) })
            var bytes = Data()
            _ = try archive.extract(entry) { bytes.append($0) }
            #expect(bytes == resource.bytes)
        }
    }
}
