//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


// The worker reply and the API share one finding shape, so findings pass through without translation.
// swiftlint:disable file_types_order
typealias ValidationDiagnostic = Components.Schemas.ValidationDiagnostic
typealias ValidationStatus = Components.Schemas.ValidationStatus
// swiftlint:enable file_types_order


extension ValidationDiagnostic {
    /// A finding of Trove's own publication and execution rules.
    static func trove(
        _ rule: String,
        path: String,
        message: String,
        severity: SeverityPayload = .error,
        nextAction: String? = nil
    ) -> Self {
        .init(severity: severity, source: .trove, rule: rule, path: path, message: message, nextAction: nextAction)
    }

    /// The error finding that explains a result that is neither valid nor invalid.
    static func reason(for status: ValidationStatus) -> Self? {
        switch status {
        case .unavailable:
            .trove(
                "validator-unavailable",
                path: "",
                message: "The FHIR validator could not be reached or returned no trustworthy result, so validity is not established.",
                nextAction: "Validate again later."
            )
        case .incomplete:
            .trove(
                "not-evaluated",
                path: "",
                message: "At least one check could not be evaluated, so validity is not established.",
                nextAction: "Review the warnings that name the check that did not run."
            )
        case .valid, .invalid:
            nil
        }
    }

    /// Errors first, then warnings and information, each in their original order; at most `limit`, with a note of the rest.
    static func ordered(_ diagnostics: [Self], limit: Int) -> [Self] {
        let order: [SeverityPayload: Int] = [.error: 0, .warning: 1, .information: 2]
        let sorted = diagnostics.enumerated()
            .sorted { (order[$0.element.severity] ?? 3, $0.offset) < (order[$1.element.severity] ?? 3, $1.offset) }
            .map(\.element)
        guard sorted.count > limit else {
            return sorted
        }
        return Array(sorted.prefix(limit))
            + [.trove("diagnostics-omitted", path: "", message: "\(sorted.count - limit) further findings are not shown.", severity: .information)]
    }

    func concerning(component: UUID) -> Self {
        var copy = self
        copy.componentId = component.uuidString
        return copy
    }
}


extension ValidationStatus {
    /// Combines the checks of one input. A definite error makes it invalid even when another check could not run;
    /// otherwise a skipped check makes it incomplete, and an unreachable validator unavailable.
    static func combined(_ statuses: some Sequence<Self>) -> Self {
        let statuses = Set(statuses)
        return [.invalid, .incomplete, .unavailable].first(where: statuses.contains) ?? .valid
    }
}
