//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPITypes
@testable import TroveServer


struct StudyReadinessCheckTests {
    private static func details(_ languages: [String] = ["en"]) throws -> StudyDetailData {
        let tags = try languages.map { try #require(LanguageTag(rawValue: $0)) }
        return try #require(StudyDetailData(
            sourceLanguage: tags[0], content: Dictionary(uniqueKeysWithValues: tags.map { ($0, StudyDetailContent(title: "Study")) })
        ))
    }

    @Test
    func completeFactsPass() throws {
        #expect(StudyReadinessCheck.diagnostics(details: try Self.details(), facts: StudyFixtures.completeReadinessFacts()).isEmpty)
    }

    @Test(arguments: ["aims", "population", "procedures", "burden", "retention", "withdrawal"])
    func eachMissingFactIsABlockerNamingItsField(fact: String) throws {
        var facts = StudyFixtures.completeReadinessFacts()
        var content = try #require(facts.content.additionalProperties["en"])
        switch fact {
        case "aims": content.aims = nil
        case "population": content.population = ""
        case "procedures": content.procedures = " \n "
        case "burden": content.burden = nil
        case "retention": content.retention = nil
        default: content.withdrawal = nil
        }
        facts.content.additionalProperties["en"] = content
        let diagnostics = StudyReadinessCheck.diagnostics(details: try Self.details(), facts: facts)
        #expect(diagnostics.count == 1)
        let finding = try #require(diagnostics.first)
        #expect(finding.rule == "readiness-\(fact)-missing" && finding.severity == .error && finding.source == .trove)
        #expect(finding.path == "readinessFacts.content.en.\(fact)" && finding.nextAction?.isEmpty == false)
    }

    @Test
    func factsInAnotherLanguageDoNotReplaceTheSourceLanguage() throws {
        let german = StudyFixtures.completeReadinessFacts(language: "de")
        let diagnostics = StudyReadinessCheck.diagnostics(details: try Self.details(["en", "de"]), facts: german)
        #expect(diagnostics.filter { $0.severity == .error }.count == 6)
        #expect(!diagnostics.contains { $0.rule == "readiness-translation-missing" })
    }

    @Test
    func otherDetailsLanguagesWithoutFactsAreAdvisories() throws {
        let diagnostics = StudyReadinessCheck.diagnostics(details: try Self.details(["en", "de"]), facts: StudyFixtures.completeReadinessFacts())
        #expect(diagnostics.map(\.rule) == ["readiness-translation-missing"])
        #expect(diagnostics.first?.severity == .warning && diagnostics.first?.path == "readinessFacts.content.de")
    }

    @Test
    func contactsNeedANameARoleAndAWayToReachThem() throws {
        var facts = StudyFixtures.completeReadinessFacts()
        facts.contacts = []
        #expect(StudyReadinessCheck.diagnostics(details: try Self.details(), facts: facts).map(\.rule) == ["readiness-contact-missing"])

        facts.contacts = [
            .init(name: "Principal Investigator", role: "Investigator", phone: "+1 650 555 0100"),
            .init(name: "", role: "Coordinator", email: "study@example.org"),
            .init(name: "Coordinator", role: "Coordinator"),
            .init(name: "Coordinator", role: "Coordinator", email: "study at example"),
            .init(name: "Coordinator", role: "Coordinator", email: "study@example")
        ]
        let diagnostics = StudyReadinessCheck.diagnostics(details: try Self.details(), facts: facts)
        #expect(diagnostics.map(\.rule) == [
            "readiness-contact-incomplete", "readiness-contact-incomplete", "readiness-contact-email", "readiness-contact-email"
        ])
        #expect(diagnostics.map(\.path) == [
            "readinessFacts.contacts[1]", "readinessFacts.contacts[2]", "readinessFacts.contacts[3].email", "readinessFacts.contacts[4].email"
        ])
    }

    @Test
    func boundsAreEnforcedOnWrite() throws {
        try StudyFixtures.completeReadinessFacts().validate()
        var facts = StudyFixtures.completeReadinessFacts()
        facts.content.additionalProperties["en-us"] = .init(aims: "Lowercase region")
        #expect(throws: ServerError.self) { try facts.validate() }
        facts = StudyFixtures.completeReadinessFacts()
        facts.content.additionalProperties["en"]?.aims = String(repeating: "a", count: 10_001)
        #expect(throws: ServerError.self) { try facts.validate() }
        facts = StudyFixtures.completeReadinessFacts()
        facts.contacts = Array(repeating: facts.contacts[0], count: 17)
        #expect(throws: ServerError.self) { try facts.validate() }
    }
}
