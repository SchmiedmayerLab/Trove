//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import MarkdownUI


/// Temporary native subset while Grove's screen and PDF renderers differ: plain paragraphs,
/// line breaks, and plain-text toggle/select/signature controls with optional plain footnotes.
/// Images, links, HTML, emphasis, code, and other block formatting are not accepted.
enum ConsentContentPolicy {
    enum ValidationError: LocalizedError {
        case unsupportedContent

        var errorDescription: String? {
            String(localized: "This consent document cannot be displayed safely in this version of the app.")
        }
    }

    private static let controlNames: Set<String> = ["toggle", "select", "signature", "option", "footnote"]

    static func validate(markdown: String) throws {
        // The pinned Grove parser tolerates unexpected EOF. This private marker checks that
        // parsing reached the end; it is never rendered, persisted, or included in a digest.
        let marker = "TROVE_CONSENT_END_\(UUID().uuidString)"
        let document: MarkdownDocument
        do {
            document = try MarkdownDocument(processing: markdown + "\n\n" + marker, customElementNames: controlNames)
        } catch {
            throw ValidationError.unsupportedContent
        }
        guard case .markdown(_, let finalText) = document.blocks.last, finalText.hasSuffix(marker) else {
            throw ValidationError.unsupportedContent
        }
        let original: MarkdownDocument
        do {
            original = try MarkdownDocument(processing: markdown, customElementNames: controlNames)
        } catch {
            throw ValidationError.unsupportedContent
        }
        var identifiers: Set<String> = []
        for block in original.blocks {
            switch block {
            case .markdown(_, let raw):
                try validateText(raw, plainLabel: false)
            case .customElement(let element):
                let id = try identifier(element)
                guard identifiers.insert(id).inserted else { throw ValidationError.unsupportedContent }
                try validateControl(element)
            }
        }
    }

    private static func validateText(_ text: String, plainLabel: Bool) throws {
        let content = MarkdownContent(text)
        // These exact tags are emitted by the pinned parser, not extracted from Markdown.
        // Its renderer escapes literal '<'; every other generated tag means unsupported content.
        let remaining = ["<p>", "</p>", "<br />"].reduce(content.renderHTML()) {
            $0.replacingOccurrences(of: $1, with: "")
        }
        guard !remaining.contains("<") else { throw ValidationError.unsupportedContent }
        if plainLabel {
            // Grove's PDF control labels use raw plainTextContents, not Markdown rendering.
            // Reject transformations such as entity decoding and escapes in those labels.
            guard content.renderPlainText().trimmingCharacters(in: .whitespacesAndNewlines)
                == text.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw ValidationError.unsupportedContent
            }
        }
    }

    private static func validateControl(_ element: MarkdownDocument.CustomElement) throws {
        switch element.name {
        case "toggle":
            try attributes(element, allowed: ["id", "initial-value", "expected-value"])
            for name in ["initial-value", "expected-value"] {
                if let value = element[attribute: name], Bool(value) == nil { throw ValidationError.unsupportedContent }
            }
            guard !element.content.isEmpty else { throw ValidationError.unsupportedContent }
            try validateLabel(element.content)
        case "select":
            try validateSelection(element)
        case "signature":
            try attributes(element, allowed: ["id"])
            guard element.content.isEmpty else { throw ValidationError.unsupportedContent }
        default:
            throw ValidationError.unsupportedContent
        }
    }

    private static func validateSelection(_ element: MarkdownDocument.CustomElement) throws {
        try attributes(element, allowed: ["id", "initial-value", "expected-value"])
        var options: Set<String> = []
        for child in element.content {
            if case .element(let option) = child, option.name == "option" {
                try attributes(option, allowed: ["id"])
                let id = try identifier(option)
                guard options.insert(id).inserted, case .text(let title) = option.content.first,
                      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ValidationError.unsupportedContent
                }
                try validateLabel(option.content, allowFootnote: false)
            } else {
                try validateLabel([child])
            }
        }
        guard !options.isEmpty else { throw ValidationError.unsupportedContent }
        if let initial = element[attribute: "initial-value"], !initial.isEmpty, !options.contains(initial) {
            throw ValidationError.unsupportedContent
        }
        if let expected = element[attribute: "expected-value"], expected != "*", !options.contains(expected) {
            throw ValidationError.unsupportedContent
        }
    }

    private static func validateLabel(_ contents: [MarkdownDocument.CustomElement.Content], allowFootnote: Bool = true) throws {
        for content in contents {
            switch content {
            case .text(let text):
                try validateText(text, plainLabel: true)
            case .element(let element):
                guard allowFootnote, element.name == "footnote", !element.content.isEmpty else {
                    throw ValidationError.unsupportedContent
                }
                try attributes(element, allowed: [])
                try validateLabel(element.content, allowFootnote: false)
            }
        }
    }

    private static func identifier(_ element: MarkdownDocument.CustomElement) throws -> String {
        guard let id = element[attribute: "id"], !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.unsupportedContent
        }
        return id
    }

    private static func attributes(_ element: MarkdownDocument.CustomElement, allowed: Set<String>) throws {
        let names = element.attributes.map(\.name)
        guard Set(names).count == names.count, names.allSatisfy(allowed.contains) else {
            throw ValidationError.unsupportedContent
        }
    }
}
