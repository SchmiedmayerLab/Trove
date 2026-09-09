//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import TroveServer


struct ConsentResponseRequirementsTests {
    private static let selection = """
        <select id=choice expected-value="*">
        Choose one.
        <option id=one>First</option>
        <option id=two>Second</option>
        </select>
        """

    private static func signature() -> SignatureData {
        var name = PersonNameComponents()
        name.givenName = "Test"
        name.familyName = "Participant"
        return .init(name: name, signature: "opaque-evidence", size: [200, 100])
    }

    @Test
    func documentOnlyPresentationDoesNotInventSignature() throws {
        let requirements = try ConsentResponseRequirements(markdown: "# Information\nA plain approved document.")
        #expect(!requirements.requiresExplicitResponse)
        #expect(requirements.requiredResponseIDs.isEmpty)
        try requirements.validate(.init())
    }

    @Test
    func optionalToggleAcceptsFalseAndMissingResponse() throws {
        let requirements = try ConsentResponseRequirements(markdown: "<toggle id=optional>Optional sharing</toggle>")
        #expect(!requirements.requiresExplicitResponse)
        try requirements.validate(.init())
        try requirements.validate(.init(toggles: ["optional": false]))
        try requirements.validate(.init(toggles: ["optional": true]))
    }

    @Test(arguments: [true, false])
    func requiredToggleNeedsExplicitMatchingResponse(expected: Bool) throws {
        let requirements = try ConsentResponseRequirements(
            markdown: "<toggle id=ack initial-value=\(expected) expected-value=\(expected)>Acknowledgement</toggle>"
        )
        #expect(requirements.requiresExplicitResponse)
        #expect(requirements.requiredResponseIDs == ["ack"])
        try requirements.validate(.init(toggles: ["ack": expected]))
        #expect(throws: ConsentResponseRequirements.ValidationError.invalidResponses) {
            try requirements.validate(.init())
        }
        #expect(throws: ConsentResponseRequirements.ValidationError.invalidResponses) {
            try requirements.validate(.init(toggles: ["ack": !expected]))
        }
    }

    @Test(arguments: ["", "invented"])
    func requiredSelectionRejectsEmptyOrUndeclaredOption(value: String) throws {
        let requirements = try ConsentResponseRequirements(markdown: Self.selection)
        #expect(throws: ConsentResponseRequirements.ValidationError.invalidResponses) {
            try requirements.validate(.init(selects: ["choice": value]))
        }
        try requirements.validate(.init(selects: ["choice": "one"]))
    }

    @Test
    func optionalSelectionStillRejectsUndeclaredOption() throws {
        let markdown = Self.selection.replacingOccurrences(of: " expected-value=\"*\"", with: "")
        let requirements = try ConsentResponseRequirements(markdown: markdown)
        try requirements.validate(.init())
        try requirements.validate(.init(selects: ["choice": ""]))
        #expect(throws: ConsentResponseRequirements.ValidationError.invalidResponses) {
            try requirements.validate(.init(selects: ["choice": "invented"]))
        }
    }

    @Test
    func specificSelectionMustMatchApprovedOption() throws {
        let markdown = Self.selection.replacingOccurrences(of: "expected-value=\"*\"", with: "expected-value=one")
        let requirements = try ConsentResponseRequirements(markdown: markdown)
        try requirements.validate(.init(selects: ["choice": "one"]))
        #expect(throws: ConsentResponseRequirements.ValidationError.invalidResponses) {
            try requirements.validate(.init(selects: ["choice": "two"]))
        }
    }

    @Test(arguments: [
        "<toggle id=ack expected-value=perhaps>Acknowledge</toggle>",
        "<toggle id=ack initial-value=perhaps>Acknowledge</toggle>",
        "<toggle id=ack expected-value=true>Acknowledge",
        "<toggle id=ack expected-value=\"true>Acknowledge</toggle>",
        "<toggle id=ack>Acknowledge</toggle>\n<signature id=ack />",
        "<toggle id=ack id=other>Acknowledge</toggle>",
        "<toggle id=ack unsupported=true>Acknowledge</toggle>",
        "<toggle id=\"\">Acknowledge</toggle>",
        "<option id=one>Orphan option</option>",
        "<select id=choice><option id=one>One</option><option id=one>Duplicate</option></select>",
        "<select id=choice><option id=\"\">Empty</option></select>",
        "<select id=choice expected-value=missing><option id=one>One</option></select>",
        "<select id=choice><signature id=nested /></select>",
        "<signature id=sig>Unsupported signature content</signature>",
        "<!-- An unclosed comment"
    ])
    func malformedOrAmbiguousDocumentIsRejected(markdown: String) {
        #expect(throws: ConsentResponseRequirements.ValidationError.invalidDocument) {
            try ConsentResponseRequirements(markdown: markdown)
        }
    }

    @Test
    func commentsDoNotCreateAcknowledgements() throws {
        let requirements = try ConsentResponseRequirements(markdown: """
            # Information
            <!-- <toggle id=hidden expected-value=true>Not a control</toggle> -->
            Ordinary content.
            """)
        #expect(!requirements.requiresExplicitResponse)
        try requirements.validate(.init())
    }

    @Test(arguments: ["```", "~~~"])
    func fencedControlExamplesAreRejectedAsAmbiguous(fence: String) {
        #expect(throws: ConsentResponseRequirements.ValidationError.invalidDocument) {
            try ConsentResponseRequirements(markdown: "\(fence)html\n<signature id=example />\n\(fence)")
        }
    }

    @Test
    func ordinaryFencedCodeIsNotAnInteractiveControl() throws {
        let requirements = try ConsentResponseRequirements(markdown: "```text\nOrdinary example\n```")
        #expect(!requirements.requiresExplicitResponse)
        try requirements.validate(.init())
    }

    @Test
    func fenceWithTrailingContentDoesNotEndCodeExample() {
        #expect(throws: ConsentResponseRequirements.ValidationError.invalidDocument) {
            try ConsentResponseRequirements(markdown: "```text\n```not-a-closing-fence\n<signature id=example />\n```")
        }
    }

    @Test(arguments: [
        UserResponses(toggles: ["unknown": true]),
        UserResponses(selects: ["ack": "true"]),
        UserResponses(signatures: ["ack": signature()])
    ])
    func undeclaredAndWrongTypeResponseKeysAreRejected(responses: UserResponses) throws {
        let requirements = try ConsentResponseRequirements(markdown: "<toggle id=ack>Acknowledge</toggle>")
        #expect(throws: ConsentResponseRequirements.ValidationError.invalidResponses) {
            try requirements.validate(responses)
        }
    }

    @Test
    func signatureRequiresNamesOpaqueEvidenceAndUsableDimensions() throws {
        let requirements = try ConsentResponseRequirements(markdown: "<signature id=sig />")
        #expect(requirements.requiredResponseIDs == ["sig"])
        try requirements.validate(.init(signatures: ["sig": Self.signature()]))
        #expect(throws: ConsentResponseRequirements.ValidationError.invalidResponses) {
            try requirements.validate(.init())
        }
    }

    @Test(arguments: ["given", "family", "signature", "zero", "negative", "infinite", "nan", "dimension-count"])
    func invalidSignatureStructureIsRejected(field: String) throws {
        let requirements = try ConsentResponseRequirements(markdown: "<signature id=sig />")
        var signature = Self.signature()
        switch field {
        case "given": signature.name.givenName = " "
        case "family": signature.name.familyName = nil
        case "signature": signature.signature = "\n"
        case "zero": signature.size = [0, 10]
        case "negative": signature.size = [-1, 10]
        case "infinite": signature.size = [.infinity, 10]
        case "nan": signature.size = [.nan, 10]
        default: signature.size = [10]
        }
        #expect(throws: ConsentResponseRequirements.ValidationError.invalidResponses) {
            try requirements.validate(.init(signatures: ["sig": signature]))
        }
    }
}
