//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


/// Deterministic presence checks of the baseline study facts that publication requires.
///
/// A fact missing in the source language of the study details, or a missing or incomplete contact, is an error that
/// blocks publication. A fact missing in another details language is a warning. The check reads presence and basic
/// form only; it does not judge the content.
enum StudyReadinessCheck {
    static func diagnostics(details: StudyDetailData, facts: StudyReadinessFacts) -> [ValidationDiagnostic] {
        var diagnostics: [ValidationDiagnostic] = []
        let source = details.sourceLanguage
        let content = facts.content.additionalProperties
        for fact in StudyReadinessFacts.facts where !present(content[source.rawValue].flatMap(fact.value)) {
            diagnostics.append(.trove(
                "readiness-\(fact.key)-missing",
                path: "readinessFacts.content.\(source).\(fact.key)",
                message: "Missing in \(source), the source language of the study details: the study's \(fact.label).",
                nextAction: "Describe the study's \(fact.label) in \(source)."
            ))
        }
        for language in details.content.keys.sorted() where language != source {
            let missing = StudyReadinessFacts.facts.filter { fact in
                !present(content[language.rawValue].flatMap(fact.value))
            }
            guard !missing.isEmpty else {
                continue
            }
            diagnostics.append(.trove(
                "readiness-translation-missing",
                path: "readinessFacts.content.\(language)",
                message: "The study details are available in \(language), but these readiness facts are not: "
                    + missing.map(\.label).joined(separator: ", ") + ".",
                severity: .warning,
                nextAction: "Describe these facts in \(language) as well, or remove \(language) from the study details."
            ))
        }
        diagnostics += contactDiagnostics(facts.contacts)
        return diagnostics
    }

    private static func contactDiagnostics(_ contacts: [Components.Schemas.StudyContact]) -> [ValidationDiagnostic] {
        guard !contacts.isEmpty else {
            return [
                .trove(
                    "readiness-contact-missing",
                    path: "readinessFacts.contacts",
                    message: "The study names no responsible contact.",
                    nextAction: "Add a contact with a name, a role and an email address or phone number."
                )
            ]
        }
        var diagnostics: [ValidationDiagnostic] = []
        for (index, contact) in contacts.enumerated() {
            let path = "readinessFacts.contacts[\(index)]"
            if !present(contact.name) || !present(contact.role) || (!present(contact.email) && !present(contact.phone)) {
                diagnostics.append(.trove(
                    "readiness-contact-incomplete",
                    path: path,
                    message: "Contact \(index + 1) needs a name, a role and an email address or phone number.",
                    nextAction: "Complete the contact or remove it."
                ))
            }
            if let email = contact.email, present(email), !validEmail(email) {
                diagnostics.append(.trove(
                    "readiness-contact-email",
                    path: "\(path).email",
                    message: "The email address of contact \(index + 1) is not an email address.",
                    nextAction: "Enter an address of the form name@example.org."
                ))
            }
        }
        return diagnostics
    }

    private static func present(_ value: String?) -> Bool {
        value.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
    }

    /// One local part and one domain with a dot, without whitespace.
    private static func validEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let local = parts.first, let domain = parts.last,
              !local.isEmpty, domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else {
            return false
        }
        return !value.contains(where: \.isWhitespace)
    }
}
