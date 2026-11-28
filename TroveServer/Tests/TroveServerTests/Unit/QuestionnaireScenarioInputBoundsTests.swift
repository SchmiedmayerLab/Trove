//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Testing
import TroveAPIServer
@testable import TroveServer


struct QuestionnaireScenarioInputBoundsTests {
    typealias Item = Components.Schemas.QuestionnaireScenarioItem
    typealias Answer = Components.Schemas.QuestionnaireScenarioAnswer

    private func validate(_ item: Item, name: String = "Scenario") throws {
        try Components.Schemas.QuestionnaireScenarioInput(scenarios: [.init(name: name, item: [item])]).validateBounds()
    }

    @Test
    func validatesEvenUnmatchedAndDeeplyNestedItems() throws {
        let longID = Item(linkId: String(repeating: "x", count: 256))
        #expect(throws: ServerError.self) {
            try validate(.init(linkId: "outer", answer: [.init(valueBoolean: true, item: [.init(linkId: "inner", item: [longID])])]))
        }
        let answers = Array(repeating: Answer(valueBoolean: true), count: 100)
        try validate(.init(linkId: "outer", answer: answers))
        #expect(throws: ServerError.self) { try validate(.init(linkId: "outer", answer: answers + answers.prefix(1))) }
    }

    @Test
    func appliesStringLimitsInUnicodeCodePoints() throws {
        let atLimit = String(repeating: "e\u{301}", count: 100)
        try validate(.init(linkId: "q1"), name: atLimit)
        #expect(throws: ServerError.self) { try validate(.init(linkId: "q1"), name: atLimit + "a") }
        #expect(throws: ServerError.self) { try validate(.init(linkId: "q1"), name: "") }
    }

    @Test
    func validatesOptionalAnswerFieldsAndListBounds() throws {
        let items = Array(repeating: Item(linkId: "q1"), count: 512)
        try validate(.init(linkId: "outer", item: items))
        #expect(throws: ServerError.self) { try validate(.init(linkId: "outer", item: items + items.prefix(1))) }
        let overlong = Answer(valueAttachment: .init(title: String(repeating: "x", count: 1_001)))
        #expect(throws: ServerError.self) { try validate(.init(linkId: "q1", answer: [overlong])) }
    }
}
