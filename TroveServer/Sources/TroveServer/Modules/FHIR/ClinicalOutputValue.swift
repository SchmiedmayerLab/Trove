//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

/// Searchable facts from a fully validated clinical output. The immutable FHIR record
/// retains the complete value, including recording attachments and component details.
enum ClinicalOutputValue: Sendable, Equatable {
    /// Preserve decimal text instead of rounding through binary floating point.
    case quantity(value: String, system: String, code: String)
    case coded(system: String, code: String)
    case components
    case group
    case sampledData
    case recording

    var resourceType: String {
        if case .recording = self { "DocumentReference" } else { "Observation" }
    }

    var kind: String {
        switch self {
        case .quantity: "quantity"
        case .coded: "coded"
        case .components: "components"
        case .group: "group"
        case .sampledData: "sampled-data"
        case .recording: "recording"
        }
    }

    var quantityValue: String? {
        if case .quantity(let value, _, _) = self { value } else { nil }
    }

    var quantitySystem: String? {
        if case .quantity(_, let system, _) = self { system } else { nil }
    }

    var quantityCode: String? {
        if case .quantity(_, _, let code) = self { code } else { nil }
    }

    var codingSystem: String? {
        if case .coded(let system, _) = self { system } else { nil }
    }

    var codingCode: String? {
        if case .coded(_, let code) = self { code } else { nil }
    }
}
