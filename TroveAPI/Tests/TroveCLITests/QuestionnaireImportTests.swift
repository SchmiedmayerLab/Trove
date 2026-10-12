//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import TroveCLI


struct QuestionnaireImportTests {
    @Test
    func preservesExactQuestionnaireTextAndIndependentResourceIdentity() throws {
        let raw = """
        {
          "resourceType": "Questionnaire",
          "id": "researcher-questionnaire-id",
          "meta": { "profile": ["https://example.test/profile"] },
          "status": "draft", "title": "Wellbeing – café"
        }

        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("trove-cli-questionnaire-\(UUID()).json")
        try Data(raw.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let input = try CLIInput.questionnaire(file: file.path, name: "Component Display Name", locale: .enUS)
        let content = try #require(input.data[.enUS])
        #expect(input.name == "Component Display Name")
        #expect(Data(content.questionnaire.utf8) == Data(raw.utf8))
    }

    @Test(arguments: [Data([0xFF]), Data("not JSON".utf8), Data("{}".utf8), Data("{\"resourceType\":\"Patient\"}".utf8)])
    func rejectsWrongResourceOrEncoding(data: Data) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("trove-cli-questionnaire-\(UUID()).json")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: CLIError.invalidInput) {
            try CLIInput.questionnaire(file: file.path, name: "Questionnaire", locale: .enUS)
        }
    }

    @Test
    func rejectsOversizedResource() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("trove-cli-questionnaire-\(UUID()).json")
        try Data(repeating: 32, count: 8 * 1024 * 1024 + 1).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: CLIError.invalidInput) {
            try CLIInput.questionnaire(file: file.path, name: "Questionnaire", locale: .enUS)
        }
    }
}
