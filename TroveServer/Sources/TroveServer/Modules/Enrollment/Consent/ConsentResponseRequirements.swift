//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation


/// Compiles Grove's validated control definitions into server-side response requirements.
struct ConsentResponseRequirements: Sendable {
    enum ValidationError: Error, Equatable {
        case invalidDocument
        case invalidResponses
    }

    private enum Requirement: Sendable {
        case toggle(expected: Bool?) // swiftlint:disable:this discouraged_optional_boolean - absent differs from required false
        case select(GroveFoundation.ConsentDocumentFormat.Selection)
        case signature

        var requiresExplicitResponse: Bool {
            switch self {
            case .toggle(let expected): expected != nil
            case .select(let selection): selection.expectedSelection != .anything(allowEmptySelection: true)
            case .signature: true
            }
        }
    }

    private let controls: [String: Requirement]

    /// Publication policy decides whether a document-only presentation is appropriate.
    var requiresExplicitResponse: Bool {
        controls.values.contains(where: \.requiresExplicitResponse)
    }

    var requiredResponseIDs: Set<String> {
        Set(controls.compactMap { $0.value.requiresExplicitResponse ? $0.key : nil })
    }

    init(markdown: String) throws {
        let document: ConsentDocumentFormat.ParsedDocument
        do {
            document = try ConsentDocumentFormat.decode(markdown)
        } catch {
            throw ValidationError.invalidDocument
        }
        var controls: [String: Requirement] = [:]
        for section in document.sections {
            switch section {
            case .markdown: break
            case .toggle(let toggle): controls[toggle.id] = .toggle(expected: toggle.expectedValue)
            case .select(let selection): controls[selection.id] = .select(selection)
            case .signature(let signature): controls[signature.id] = .signature
            case .custom: throw ValidationError.invalidDocument
            }
        }
        self.controls = controls
    }

    func validate(_ responses: UserResponses) throws {
        try validateKnownResponseIDs(responses)
        for (id, requirement) in controls {
            switch requirement {
            case .toggle(let expected):
                if let expected, responses.toggles[id] != expected { throw ValidationError.invalidResponses }
            case .select(let selection):
                try Self.validateSelection(responses.selects[id], definition: selection)
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

    private static func validateSelection(_ value: String?, definition: ConsentDocumentFormat.Selection) throws {
        let value = value ?? ""
        guard value.isEmpty || definition.options.contains(where: { $0.id == value }) else { throw ValidationError.invalidResponses }
        switch definition.expectedSelection {
        case .anything(allowEmptySelection: true): break
        case .anything(allowEmptySelection: false):
            guard !value.isEmpty else { throw ValidationError.invalidResponses }
        case .option(let id):
            guard value == id else { throw ValidationError.invalidResponses }
        }
    }
}
