//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

enum ComponentType: String, Codable, Sendable {
    case informational
    case questionnaire
    case healthDataCollection

    var supportsSchedules: Bool {
        switch self {
        case .informational, .questionnaire:
            true
        case .healthDataCollection:
            false
        }
    }
}
