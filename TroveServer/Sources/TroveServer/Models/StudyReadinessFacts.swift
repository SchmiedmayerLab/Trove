//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


typealias StudyReadinessFacts = Components.Schemas.StudyReadinessFacts


extension StudyReadinessFacts {
    struct Fact: Sendable {
        let key: String
        let label: String
        let value: @Sendable (Components.Schemas.StudyReadinessContent) -> String?
    }

    static var empty: Self { .init(content: .init(), contacts: []) }

    /// The text facts, in the order the readiness check reports them.
    static var facts: [Fact] {
        [
            .init(key: "aims", label: "aims") { $0.aims },
            .init(key: "population", label: "population") { $0.population },
            .init(key: "procedures", label: "procedures") { $0.procedures },
            .init(key: "burden", label: "participant burden") { $0.burden },
            .init(key: "retention", label: "data retention") { $0.retention },
            .init(key: "withdrawal", label: "withdrawal") { $0.withdrawal }
        ]
    }
}


extension StudyReadinessFacts {
    private static var invalid: ServerError {
        .badRequest("Readiness facts must be keyed by language tags, with at most 16 contacts and texts within their length limits")
    }

    /// Bounds that the generated types do not enforce on decoding.
    func validate() throws {
        guard contacts.count <= 16,
              content.additionalProperties.count <= 64,
              content.additionalProperties.keys.allSatisfy({ LanguageTag(rawValue: $0) != nil }),
              content.additionalProperties.values.allSatisfy({ entry in
                  Self.facts.allSatisfy { ($0.value(entry)?.count ?? 0) <= 10_000 }
              }),
              contacts.allSatisfy({ contact in
                  contact.name.count <= 200 && contact.role.count <= 200
                      && (contact.email?.count ?? 0) <= 320 && (contact.phone?.count ?? 0) <= 64
              }) else {
            throw Self.invalid
        }
    }
}
