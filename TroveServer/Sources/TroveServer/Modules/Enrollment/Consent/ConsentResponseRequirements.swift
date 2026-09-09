//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation


/// Compiles the existing Grove consent controls, not a separate study or form schema.
struct ConsentResponseRequirements: Sendable {
    enum ValidationError: Error, Equatable {
        case invalidDocument
        case invalidResponses
    }

    private enum Selection: Sendable {
        case optional
        case required
        case specific(String)
    }

    private enum Requirement: Sendable {
        case toggle(expected: Bool?) // swiftlint:disable:this discouraged_optional_boolean - absent differs from required false
        case select(options: Set<String>, expected: Selection)
        case signature

        var requiresExplicitResponse: Bool {
            switch self {
            case .toggle(let expected): expected != nil
            case .select(_, .optional): false
            case .select, .signature: true
            }
        }
    }

    private static let elementNames: Set<String> = ["toggle", "select", "signature", "option", "footnote"]

    private let controls: [String: Requirement]

    /// Publication policy decides whether a document-only presentation is appropriate.
    var requiresExplicitResponse: Bool {
        controls.values.contains(where: \.requiresExplicitResponse)
    }

    var requiredResponseIDs: Set<String> {
        Set(controls.compactMap { $0.value.requiresExplicitResponse ? $0.key : nil })
    }

    init(markdown: String) throws {
        try Self.rejectAmbiguousFencedControls(in: markdown)
        // The pinned parser tolerates unexpected EOF. Verify complete consumption without
        // persisting this marker or changing the approved presentation's bytes/digest.
        // Follow-up: replace this guard with Grove's strict parsing API when available.
        let marker = "TROVE_CONSENT_PARSE_END_\(UUID().uuidString)"
        let document: MarkdownDocument
        do {
            document = try MarkdownDocument(processing: markdown + "\n\n" + marker, customElementNames: Self.elementNames)
        } catch {
            throw ValidationError.invalidDocument
        }
        guard case .markdown(_, let lastText) = document.blocks.last, lastText.hasSuffix(marker) else {
            throw ValidationError.invalidDocument
        }
        var controls: [String: Requirement] = [:]
        for block in document.blocks {
            guard case .customElement(let element) = block else { continue }
            let id = try Self.identifier(of: element)
            guard controls[id] == nil else { throw ValidationError.invalidDocument }
            controls[id] = try Self.requirement(for: element)
        }
        self.controls = controls
    }

    func validate(_ responses: UserResponses) throws {
        try validateKnownResponseIDs(responses)
        for (id, requirement) in controls {
            switch requirement {
            case .toggle(let expected):
                if let expected, responses.toggles[id] != expected { throw ValidationError.invalidResponses }
            case let .select(options, expected):
                try Self.validateSelection(responses.selects[id], options: options, expected: expected)
            case .signature:
                try Self.validateSignature(responses.signatures[id])
            }
        }
    }

    private func validateKnownResponseIDs(_ responses: UserResponses) throws {
        for id in responses.toggles.keys {
            guard case .toggle = controls[id] else { throw ValidationError.invalidResponses }
        }
        for id in responses.selects.keys {
            guard case .select = controls[id] else { throw ValidationError.invalidResponses }
        }
        for id in responses.signatures.keys {
            guard case .signature = controls[id] else { throw ValidationError.invalidResponses }
        }
    }
}


extension ConsentResponseRequirements {
    private static func validateSignature(_ signature: SignatureData?) throws {
        guard let signature,
              !(signature.name.givenName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !(signature.name.familyName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !signature.signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              signature.size.count == 2,
              signature.size.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw ValidationError.invalidResponses
        }
        // Opaque evidence presence is not verification of handwriting or signer identity.
    }

    private static func identifier(of element: MarkdownDocument.CustomElement) throws -> String {
        guard let id = element[attribute: "id"], !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(element.attributes.map(\.name)).count == element.attributes.count else {
            throw ValidationError.invalidDocument
        }
        return id
    }

    private static func requirement(for element: MarkdownDocument.CustomElement) throws -> Requirement {
        switch element.name {
        case "toggle":
            try validateAttributes(of: element, allowed: ["id", "initial-value", "expected-value"])
            try validatePrompt(element.content)
            _ = try booleanAttribute("initial-value", of: element)
            return .toggle(expected: try booleanAttribute("expected-value", of: element))
        case "select":
            return try selectionRequirement(for: element)
        case "signature":
            try validateAttributes(of: element, allowed: ["id"])
            guard element.content.isEmpty else { throw ValidationError.invalidDocument }
            return .signature
        default:
            throw ValidationError.invalidDocument
        }
    }

    private static func selectionRequirement(for element: MarkdownDocument.CustomElement) throws -> Requirement {
        try validateAttributes(of: element, allowed: ["id", "initial-value", "expected-value"])
        let options = try selectionOptions(in: element.content)
        if let initial = element[attribute: "initial-value"], !initial.isEmpty, !options.contains(initial) {
            throw ValidationError.invalidDocument
        }
        let expected: Selection
        switch element[attribute: "expected-value"] {
        case nil: expected = .optional
        case "*": expected = .required
        case .some(let id):
            guard options.contains(id) else { throw ValidationError.invalidDocument }
            expected = .specific(id)
        }
        return .select(options: options, expected: expected)
    }

    private static func selectionOptions(in contents: [MarkdownDocument.CustomElement.Content]) throws -> Set<String> {
        var options: Set<String> = []
        for content in contents {
            guard case .element(let child) = content else { continue }
            if child.name == "footnote" {
                try validatePrompt(child.content)
                continue
            }
            guard child.name == "option" else { throw ValidationError.invalidDocument }
            let id = try identifier(of: child)
            try validateAttributes(of: child, allowed: ["id"])
            guard options.insert(id).inserted, case .text(let text) = child.content.first, !text.isEmpty else {
                throw ValidationError.invalidDocument
            }
            guard child.content.allSatisfy({ if case .text = $0 { true } else { false } }) else {
                throw ValidationError.invalidDocument
            }
        }
        guard !options.isEmpty else { throw ValidationError.invalidDocument }
        return options
    }

    private static func validateSelection(_ value: String?, options: Set<String>, expected: Selection) throws {
        let value = value ?? ""
        guard value.isEmpty || options.contains(value) else { throw ValidationError.invalidResponses }
        switch expected {
        case .optional: break
        case .required:
            guard !value.isEmpty else { throw ValidationError.invalidResponses }
        case .specific(let id):
            guard value == id else { throw ValidationError.invalidResponses }
        }
    }

    // swiftlint:disable:next discouraged_optional_boolean - absent differs from required false
    private static func booleanAttribute(_ name: String, of element: MarkdownDocument.CustomElement) throws -> Bool? {
        guard let raw = element[attribute: name] else {
            return nil
        }
        guard let value = Bool(raw) else { throw ValidationError.invalidDocument }
        return value
    }

    private static func validateAttributes(of element: MarkdownDocument.CustomElement, allowed: Set<String>) throws {
        guard element.attributes.allSatisfy({ allowed.contains($0.name) }) else { throw ValidationError.invalidDocument }
    }

    private static func validatePrompt(_ contents: [MarkdownDocument.CustomElement.Content]) throws {
        guard !contents.isEmpty else { throw ValidationError.invalidDocument }
        for content in contents {
            if case .element(let child) = content {
                guard child.name == "footnote", child.content.allSatisfy({ if case .text = $0 { true } else { false } }) else {
                    throw ValidationError.invalidDocument
                }
            }
        }
    }

    private static func rejectAmbiguousFencedControls(in markdown: String) throws {
        // Grove's processor is not a full Markdown parser. Do not interpret an example
        // inside a code fence as an actual consent control.
        var fence: (character: Character, count: Int)?
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if let first = trimmed.first, first == "`" || first == "~" {
                let count = trimmed.prefix(while: { $0 == first }).count
                if count >= 3 {
                    if let active = fence {
                        if first == active.character, count >= active.count,
                           trimmed.dropFirst(count).allSatisfy(\.isWhitespace) {
                            fence = nil
                        }
                    } else {
                        fence = (first, count)
                    }
                    continue
                }
            }
            if fence != nil, elementNames.contains(where: { line.contains("<\($0)") }) {
                throw ValidationError.invalidDocument
            }
        }
    }
}
